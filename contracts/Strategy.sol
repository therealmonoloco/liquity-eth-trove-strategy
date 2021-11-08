// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/liquity/IBorrowerOperations.sol";
import "../interfaces/liquity/IPriceFeed.sol";
import "../interfaces/liquity/ITroveManager.sol";
import "../interfaces/uniswap/ISwapRouter.sol";
import "../interfaces/weth/IWETH9.sol";
import "../interfaces/yearn/IBaseFee.sol";
import "../interfaces/yearn/IVault.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // LUSD token
    IERC20 internal constant investmentToken =
        IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);

    // Wrapped ether
    IWETH9 internal constant WETH =
        IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Chainlink ETH:USD with Tellor ETH:USD as fallback
    IPriceFeed internal constant priceFeed =
        IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De);

    // Provider to read current block's base fee
    IBaseFee internal constant baseFeeProvider =
        IBaseFee(0xf8d0Ec04e94296773cE20eFbeeA82e76220cD549);

    // Common interface for the Trove Manager
    IBorrowerOperations internal constant borrowerOperations =
        IBorrowerOperations(0x24179CD81c9e782A4096035f7eC97fB8B783e007);

    // Trove Manager
    ITroveManager internal constant troveManager =
        ITroveManager(0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2);

    // Uniswap v3 router to do LUSD->ETH
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // 100%
    uint256 internal constant MAX_BPS = 1e18;

    // Maximum loss on withdrawal from yVault
    uint256 internal constant MAX_LOSS_BPS = 10000;

    // Minimum debt in LUSD allowed by the protocol
    uint256 internal constant MIN_DEBT = 2000 * 1e18;

    // LUSD yVault
    IVault public yVault;

    // Our desired collaterization ratio
    uint256 public collateralizationRatio;

    // Allow the collateralization ratio to drift a bit in order to avoid cycles
    uint256 public rebalanceTolerance;

    // Max acceptable base fee to take more debt or harvest
    uint256 public maxAcceptableBaseFee;

    // Max fee slippage to accept when borrowing LUSD
    uint256 public maxFeePercentage;

    // Max acceptable fee to pay when borrowing LUSD (min is 0.5%)
    uint256 public maxBorrowingRate;

    // Maximum acceptable loss on withdrawal. Default to 1%.
    uint256 public maxLoss;

    // Minimum collateralization ratio to enforce
    uint256 internal minCollatRatio;

    // If set to true the strategy will never try to repay debt by selling want
    bool public leaveDebtBehind;

    constructor(address _vault, address _yVault) public BaseStrategy(_vault) {
        yVault = IVault(_yVault);

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;

        // Current ratio can drift (collateralizationRatio - rebalanceTolerance, collateralizationRatio + rebalanceTolerance)
        // Allow additional 30% in any direction (170, 230) by default
        rebalanceTolerance = (30 * MAX_BPS) / 100;

        // Use 200% as target
        collateralizationRatio = (200 * MAX_BPS) / 100;

        // Never allow rebalancing band to go below 150%
        // Troves below 150% become liquidatable if system goes into Recovery Mode
        minCollatRatio = (150 * MAX_BPS) / 100;

        // Maximum 0.01% fee slippage
        maxFeePercentage = 10000000000000000;

        // Define maximum acceptable loss on withdrawal to be 1%.
        maxLoss = 100;

        // Define maximum acceptable borrowing fee to be 0.55%
        maxBorrowingRate = 5500000000000000;

        // Set max acceptable base fee to take on more debt to 60 gwei
        maxAcceptableBaseFee = 60 gwei;

        // If we lose money in yvLUSD then we are not OK selling want to repay it
        leaveDebtBehind = true;
    }

    // Strategy should be able to receive ETH
    receive() external payable {}

    // ----------------- SETTERS & MIGRATION -----------------

    // Maximum acceptable base fee of current block to take on more debt
    function setMaxAcceptableBaseFee(uint256 _maxAcceptableBaseFee)
        external
        onlyEmergencyAuthorized
    {
        maxAcceptableBaseFee = _maxAcceptableBaseFee;
    }

    // Target collateralization ratio to maintain within bounds
    function setCollateralizationRatio(uint256 _collateralizationRatio)
        external
        onlyEmergencyAuthorized
    {
        require(
            _collateralizationRatio.sub(rebalanceTolerance) > minCollatRatio
        ); // dev: desired collateralization ratio is too low
        collateralizationRatio = _collateralizationRatio;
    }

    // Rebalancing bands (collat ratio - tolerance, collat_ratio + tolerance)
    function setRebalanceTolerance(uint256 _rebalanceTolerance)
        external
        onlyEmergencyAuthorized
    {
        require(
            collateralizationRatio.sub(_rebalanceTolerance) > minCollatRatio
        ); // dev: desired rebalance tolerance makes allowed ratio too low
        rebalanceTolerance = _rebalanceTolerance;
    }

    // Max slippage to accept when withdrawing from yVault
    function setMaxLoss(uint256 _maxLoss) external onlyVaultManagers {
        require(_maxLoss <= MAX_LOSS_BPS); // dev: invalid value for max loss
        maxLoss = _maxLoss;
    }

    // If set to true the strategy will never sell want to repay debts
    function setLeaveDebtBehind(bool _leaveDebtBehind)
        external
        onlyEmergencyAuthorized
    {
        leaveDebtBehind = _leaveDebtBehind;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "StrategyLiquityTroveETH";
    }

    function delegatedAssets() external view override returns (uint256) {
        return _convertInvestmentTokenToWant(_valueOfInvestment());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            balanceOfWant()
                .add(balanceOfTrove())
                .add(_convertInvestmentTokenToWant(balanceOfInvestmentToken()))
                .add(_convertInvestmentTokenToWant(_valueOfInvestment()))
                .sub(_convertInvestmentTokenToWant(balanceOfDebt()));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Claim rewards from yVault
        _takeYVaultProfit();

        // TODO: handle potential ETH rewards

        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding.add(_profit)
        );
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Make sure lastGoodPrice is up to date
        priceFeed.fetchPrice();

        // If we have enough want to deposit more into the trove, we do it
        // Do not skip the rest of the function as it may need to repay or take on more debt
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            uint256 amountToDeposit = wantBalance.sub(_debtOutstanding);
            _depositToTrove(amountToDeposit);
        }

        // Allow the ratio to move a bit in either direction to avoid cycles
        uint256 currentRatio = getCurrentTroveRatio();
        if (currentRatio < collateralizationRatio.sub(rebalanceTolerance)) {
            _repayDebt(currentRatio);
        } else if (
            currentRatio > collateralizationRatio.add(rebalanceTolerance) &&
            troveManager.getBorrowingRate() < maxBorrowingRate
        ) {
            _mintMoreInvestmentToken();
        }

        // If we have anything left to invest then deposit into the yVault
        _depositInvestmentTokenInYVault();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();

        // Check if we can handle it without freeing collateral
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // We only need to free the amount of want not readily available
        uint256 amountToFree = _amountNeeded.sub(balance);

        uint256 price = priceFeed.fetchPrice();
        uint256 collateralBalance = balanceOfTrove();

        // We cannot free more than what we have locked
        amountToFree = Math.min(amountToFree, collateralBalance);

        uint256 totalDebt = balanceOfDebt();

        // If for some reason we do not have debt, make sure the operation does not revert
        if (totalDebt == 0) {
            totalDebt = 1;
        }

        uint256 toFreeIT = amountToFree.mul(price).div(MAX_BPS);
        uint256 collateralIT = collateralBalance.mul(price).div(MAX_BPS);
        uint256 newRatio =
            collateralIT.sub(toFreeIT).mul(MAX_BPS).div(totalDebt);

        // Attempt to repay necessary debt to restore the target collateralization ratio
        _repayDebt(newRatio);

        // Unlock as much collateral as possible while keeping the target ratio
        amountToFree = Math.min(amountToFree, _maxWithdrawal());

        _withdrawCollateralFromTrove(amountToFree);

        // If we still need more want to repay, we may need to unlock some collateral to sell
        if (
            !leaveDebtBehind &&
            balanceOfWant() < _amountNeeded &&
            balanceOfDebt() > 0
        ) {
            _sellCollateralToRepayRemainingDebtIfNeeded();
        }

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    function harvestTrigger(uint256 callCost)
        public
        view
        override
        returns (bool)
    {
        return isCurrentBaseFeeAcceptable() && super.harvestTrigger(callCost);
    }

    function tendTrigger(uint256 callCostInWei)
        public
        view
        override
        returns (bool)
    {
        // Nothing to adjust if there is no collateral locked or we have no debt
        if (balanceOfTrove() == 0) {
            return false;
        }

        uint256 currentRatio = getCurrentTroveRatio();

        // If we need to repay debt and are outside the tolerance bands,
        // we do it regardless of the call cost
        if (currentRatio < collateralizationRatio.sub(rebalanceTolerance)) {
            return true;
        }

        // If planets are aligned then mint more LUSD
        return
            currentRatio > collateralizationRatio.add(rebalanceTolerance) &&
            balanceOfDebt() > 0 &&
            troveManager.getBorrowingRate() < maxBorrowingRate &&
            isCurrentBaseFeeAcceptable();
    }

    function prepareMigration(address _newStrategy) internal override {
        // Trove cannot be migrated so nothing to do here
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei.mul(priceFeed.lastGoodPrice()).div(1e18);
    }

    // ----------------- PUBLIC BALANCES AND CALCS -----------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfInvestmentToken() public view returns (uint256) {
        return investmentToken.balanceOf(address(this));
    }

    function balanceOfDebt() public view returns (uint256) {
        return troveManager.getTroveDebt(address(this));
    }

    function balanceOfTrove() public view returns (uint256) {
        return troveManager.getTroveColl(address(this));
    }

    function getCurrentTroveRatio() public view returns (uint256) {
        return
            balanceOfTrove().mul(priceFeed.lastGoodPrice()).div(
                balanceOfDebt()
            );
    }

    // Check if current block's base fee is under max allowed base fee
    function isCurrentBaseFeeAcceptable() public view returns (bool) {
        uint256 baseFee;
        try baseFeeProvider.basefee_global() returns (uint256 currentBaseFee) {
            baseFee = currentBaseFee;
        } catch {
            // Useful for testing until ganache supports london fork
            // Hard-code current base fee to 1000 gwei
            // This should also help keepers that run in a fork without
            // baseFee() to avoid reverting and potentially abandoning the job
            baseFee = 1000 * 1e9;
        }

        return baseFee <= maxAcceptableBaseFee;
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _withdrawLUSDFromTrove(uint256 amount) internal {
        // TODO: provide hints
        borrowerOperations.withdrawLUSD(
            maxFeePercentage,
            amount,
            address(this),
            address(this)
        );
    }

    function _withdrawCollateralFromTrove(uint256 amount) internal {
        // TODO: adjust upper and lower hints
        // TODO: repaying all debt should take collateral out of the trove to avoid redemptions
        borrowerOperations.withdrawColl(amount, address(this), address(this));

        // Wrap ETH
        WETH.deposit();
    }

    function _repayDebt(uint256 currentRatio) internal {
        uint256 currentDebt = balanceOfDebt();

        // Nothing to repay if we are over the collateralization ratio
        // or there is no debt
        if (currentRatio > collateralizationRatio || currentDebt == 0) {
            return;
        }

        // ratio = collateral / debt
        // collateral = current_ratio * current_debt
        // collateral amount is invariant here so we want to find new_debt
        // so that new_debt * desired_ratio = current_debt * current_ratio
        // new_debt = current_debt * current_ratio / desired_ratio
        // and the amount to repay is the difference between current_debt and new_debt
        uint256 newDebt =
            currentDebt.mul(currentRatio).div(collateralizationRatio);
        uint256 amountToRepay;

        // Liquity does not allow having less debt than 2,000 LUSD
        if (newDebt <= MIN_DEBT) {
            // If we sold want to repay debt we will have LUSD readily available in the strategy
            // This means we need to count both yvLUSD shares and current LUSD balance
            uint256 totalInvestmentAvailableToRepay =
                _valueOfInvestment().add(balanceOfInvestmentToken());
            if (totalInvestmentAvailableToRepay >= currentDebt) {
                // Pay the entire debt if we have enough investment token
                amountToRepay = currentDebt;
            } else {
                // Pay just 0.1 cent above min debt (best effort without liquidating want)
                amountToRepay = currentDebt.sub(MIN_DEBT).sub(1e15);
            }
        } else {
            // If we are not near the debt floor then just pay the exact amount
            // needed to obtain a healthy collateralization ratio
            amountToRepay = currentDebt.sub(newDebt);
        }
        uint256 balanceIT = balanceOfInvestmentToken();
        if (amountToRepay > balanceIT) {
            _withdrawFromYVault(amountToRepay.sub(balanceIT));
        }
        _repayInvestmentTokenDebt(amountToRepay);
    }

    function _sellCollateralToRepayRemainingDebtIfNeeded() internal {
        uint256 currentInvestmentValue = _valueOfInvestment();

        uint256 investmentLeftToAcquire =
            balanceOfDebt().sub(currentInvestmentValue);

        uint256 investmentLeftToAcquireInWant =
            _convertInvestmentTokenToWant(investmentLeftToAcquire);

        if (investmentLeftToAcquireInWant <= balanceOfWant()) {
            // TODO: _buyInvestmentTokenWithWant(investmentLeftToAcquire);
            _repayDebt(0);
            // TODO: should we use closeTrove() instead?
            _withdrawCollateralFromTrove(balanceOfTrove());
        }
    }

    // Mint the maximum LUSD possible for the locked collateral
    // Assumes borrowing rate is acceptable and has been checked before calling
    function _mintMoreInvestmentToken() internal {
        uint256 price = priceFeed.fetchPrice();
        uint256 amount = balanceOfTrove();

        uint256 lusdToMint =
            amount.mul(price).mul(MAX_BPS).div(collateralizationRatio).div(
                MAX_BPS
            );
        lusdToMint = lusdToMint.sub(balanceOfDebt());

        _withdrawLUSDFromTrove(lusdToMint);
    }

    function _withdrawFromYVault(uint256 _amountIT) internal returns (uint256) {
        if (_amountIT == 0) {
            return 0;
        }
        // No need to check allowance because the contract == token
        uint256 balancePrior = balanceOfInvestmentToken();
        uint256 sharesToWithdraw =
            Math.min(
                _investmentTokenToYShares(_amountIT),
                yVault.balanceOf(address(this))
            );
        if (sharesToWithdraw == 0) {
            return 0;
        }
        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
        return balanceOfInvestmentToken().sub(balancePrior);
    }

    function _depositInvestmentTokenInYVault() internal {
        uint256 balanceIT = balanceOfInvestmentToken();
        if (balanceIT > 0) {
            _checkAllowance(
                address(yVault),
                address(investmentToken),
                balanceIT
            );

            yVault.deposit();
        }
    }

    function _repayInvestmentTokenDebt(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        uint256 debt = balanceOfDebt();
        uint256 balanceIT = balanceOfInvestmentToken();

        // We cannot pay more than loose balance
        amount = Math.min(amount, balanceIT);

        // We cannot pay more than we owe
        amount = Math.min(amount, debt);

        _checkAllowance(
            address(borrowerOperations),
            address(investmentToken),
            amount
        );

        if (amount > 0) {
            // TODO: provide _upperHint and _lowerHint to consume less gas
            borrowerOperations.repayLUSD(amount, address(this), address(this));
        }
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    function _takeYVaultProfit() internal {
        uint256 _debt = balanceOfDebt();
        uint256 _valueInVault = _valueOfInvestment();
        if (_debt >= _valueInVault) {
            return;
        }

        uint256 profit = _valueInVault.sub(_debt);
        uint256 ySharesToWithdraw = _investmentTokenToYShares(profit);
        if (ySharesToWithdraw > 0) {
            yVault.withdraw(ySharesToWithdraw, address(this), maxLoss);
            _sellLUSDforWETH();
        }
    }

    function _depositToTrove(uint256 amount) internal {
        if (amount == 0 || troveManager.getBorrowingRate() > maxBorrowingRate) {
            return;
        }

        uint256 price = priceFeed.fetchPrice();
        uint256 lusdToMint =
            amount.mul(price).mul(MAX_BPS).div(collateralizationRatio).div(
                MAX_BPS
            );

        // Need to unwrap WETH to ETH
        WETH.withdraw(amount);

        if (balanceOfTrove() == 0) {
            // If this is the first time we need to open a new trove
            // TODO: provide _upperHint and _lowerHint to consume less gas
            borrowerOperations.openTrove{value: amount}(
                maxFeePercentage,
                lusdToMint,
                address(this),
                address(this)
            );
        } else {
            // Add collateral to existing trove and mint excess LUSD
            // TODO: provide _upperHint and _lowerHint to consume less gas
            borrowerOperations.addColl{value: amount}(
                address(this),
                address(this)
            );
            _withdrawLUSDFromTrove(lusdToMint);
        }
    }

    // Returns maximum collateral to withdraw while maintaining the target collateralization ratio
    function _maxWithdrawal() internal view returns (uint256) {
        // Denominated in want
        uint256 totalCollateral = balanceOfTrove();

        // Denominated in investment token
        uint256 totalDebt = balanceOfDebt();

        // If there is no debt to repay we can withdraw all the locked collateral
        if (totalDebt == 0) {
            return totalCollateral;
        }

        uint256 price = priceFeed.lastGoodPrice();

        // Min collateral in want that needs to be locked with the outstanding debt
        // Allow going to the lower rebalancing band
        uint256 minCollateral =
            collateralizationRatio
                .sub(rebalanceTolerance)
                .mul(totalDebt)
                .mul(MAX_BPS)
                .div(price)
                .div(MAX_BPS);

        // If we are under collateralized then it is not safe for us to withdraw anything
        if (minCollateral > totalCollateral) {
            return 0;
        }

        return totalCollateral.sub(minCollateral);
    }

    // ----------------- INTERNAL CALCS -----------------

    function _valueOfInvestment() internal view returns (uint256) {
        return
            yVault.balanceOf(address(this)).mul(yVault.pricePerShare()).div(
                10**yVault.decimals()
            );
    }

    function _investmentTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(10**yVault.decimals()).div(yVault.pricePerShare());
    }

    // ----------------- TOKEN CONVERSIONS -----------------

    function _convertInvestmentTokenToWant(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(1e18).div(priceFeed.lastGoodPrice());
    }

    function _sellLUSDforWETH() internal {
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams(
                address(investmentToken), // tokenIn
                address(WETH), // tokenOut
                3000, // 0.3% fee
                address(this), // recipient
                now, // deadline
                investmentToken.balanceOf(address(this)), // amountIn
                0, // amountOut
                0 // sqrtPriceLimitX96
            );

        router.exactInputSingle(params);
    }
}
