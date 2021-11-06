// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/liquity/IBorrowerOperations.sol";
import "../interfaces/liquity/IPriceFeed.sol";
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
    }

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
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
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
}
