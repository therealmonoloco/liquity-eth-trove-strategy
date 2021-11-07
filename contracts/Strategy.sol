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
import "../interfaces/yearn/IBaseFee.sol";
import "../interfaces/yearn/IVault.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // LUSD token
    IERC20 internal constant investmentToken =
        IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);

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

    // 100%
    uint256 internal constant MAX_BPS = 1e18;

    // Maximum loss on withdrawal from yVault
    uint256 internal constant MAX_LOSS_BPS = 10000;

    // LUSD yVault
    IVault public yVault;

    // Our desired collaterization ratio
    uint256 public collateralizationRatio;

    // Allow the collateralization ratio to drift a bit in order to avoid cycles
    uint256 public rebalanceTolerance;

    // Max acceptable base fee to take more debt or harvest
    uint256 public maxAcceptableBaseFee;

    // Maximum acceptable loss on withdrawal. Default to 0.01%.
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

        // Define maximum acceptable loss on withdrawal to be 0.01%.
        maxLoss = 1;

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
        // TODO: Build a more accurate estimate using the value of all positions in terms of `want`
        return want.balanceOf(address(this));
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
        // Make sure price is up to date
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
            currentRatio > collateralizationRatio.add(rebalanceTolerance)
        ) {
            // TODO: _mintMoreInvestmentToken();
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
        // TODO: amountToFree = Math.min(amountToFree, _maxWithdrawal());
        // TODO: _freeCollateralAndRepayDai(amountToFree, 0);

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
        // TODO: conditions to harvest
        // return isCurrentBaseFeeAcceptable() && super.harvestTrigger(callCost);
    }

    function tendTrigger(uint256 callCostInWei)
        public
        view
        override
        returns (bool)
    {
        // Nothing to adjust if there is no collateral locked
        if (balanceOfTrove() == 0) {
            return false;
        }

        uint256 currentRatio = getCurrentTroveRatio();

        // If we need to repay debt and are outside the tolerance bands,
        // we do it regardless of the call cost
        if (currentRatio < collateralizationRatio.sub(rebalanceTolerance)) {
            return true;
        }

        // TODO: conditions to mint more LUSD
        return false;
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        // TODO: redeem all collateral and send it to new strategy
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
        // TODO
    }

    function balanceOfTrove() public view returns (uint256) {
        // TODO
    }

    function getCurrentTroveRatio() public view returns (uint256) {
        // TODO
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _repayDebt(uint256 currentRatio) internal {
        // uint256 currentDebt = balanceOfDebt();
        // // Nothing to repay if we are over the collateralization ratio
        // // or there is no debt
        // if (currentRatio > collateralizationRatio || currentDebt == 0) {
        //     return;
        // }
        // // ratio = collateral / debt
        // // collateral = current_ratio * current_debt
        // // collateral amount is invariant here so we want to find new_debt
        // // so that new_debt * desired_ratio = current_debt * current_ratio
        // // new_debt = current_debt * current_ratio / desired_ratio
        // // and the amount to repay is the difference between current_debt and new_debt
        // uint256 newDebt =
        //     currentDebt.mul(currentRatio).div(collateralizationRatio);
        // uint256 amountToRepay;
        // // Maker will revert if the outstanding debt is less than a debt floor
        // // called 'dust'. If we are there we need to either pay the debt in full
        // // or leave at least 'dust' balance (10,000 DAI for YFI-A)
        // uint256 debtFloor = MakerDaiDelegateLib.debtFloor(ilk);
        // if (newDebt <= debtFloor) {
        //     // If we sold want to repay debt we will have DAI readily available in the strategy
        //     // This means we need to count both yvDAI shares and current DAI balance
        //     uint256 totalInvestmentAvailableToRepay =
        //         _valueOfInvestment().add(balanceOfInvestmentToken());
        //     if (totalInvestmentAvailableToRepay >= currentDebt) {
        //         // Pay the entire debt if we have enough investment token
        //         amountToRepay = currentDebt;
        //     } else {
        //         // Pay just 0.1 cent above debtFloor (best effort without liquidating want)
        //         amountToRepay = currentDebt.sub(debtFloor).sub(1e15);
        //     }
        // } else {
        //     // If we are not near the debt floor then just pay the exact amount
        //     // needed to obtain a healthy collateralization ratio
        //     amountToRepay = currentDebt.sub(newDebt);
        // }
        // uint256 balanceIT = balanceOfInvestmentToken();
        // if (amountToRepay > balanceIT) {
        //     _withdrawFromYVault(amountToRepay.sub(balanceIT));
        // }
        // _repayInvestmentTokenDebt(amountToRepay);
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
            // TODO: _freeCollateralAndRepayDai(balanceOfMakerVault(), 0);
        }
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
            _sellAForB(
                balanceOfInvestmentToken(),
                address(investmentToken),
                address(want)
            );
        }
    }

    function _depositToTrove(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        // TODO: add collateral and borrow LUSD
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

    function _sellAForB(
        uint256 _amount,
        address tokenA,
        address tokenB
    ) internal {
        // TODO swap
    }
}
