// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEgine__NeedsMoreThanZero();
    error DSCEgine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEgine__TokenNotAllowed();
    error DSCEgine__TransferFailed();
    error DSCEgine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    uint256 private constant _ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant _PRECISION = 1e18;
    uint256 private constant _LIQUIDIATION_THRESHOLD = 50;
    uint256 private constant _LIQUIDIATION_PRECISION = 100;
    uint256 private constant _MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant _LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private _priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private _collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private _dscMinted;
    address[] private _collateralTokens;
    DecentralizedStableCoin private immutable _dsc;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEgine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (_priceFeeds[token] == address(0)) {
            revert DSCEgine__TokenNotAllowed();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedsAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedsAddress.length) {
            revert DSCEgine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            _priceFeeds[tokenAddresses[i]] = priceFeedsAddress[i];
            _collateralTokens.push(tokenAddresses[i]);
        }
        _dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDSc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEgine__TransferFailed();
        }
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        _dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = _dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= _MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * _LIQUIDATION_BONUS) / _LIQUIDIATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        _dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = _dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEgine__TransferFailed();
        }
        _dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        _collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEgine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = _dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * _LIQUIDIATION_THRESHOLD) / _LIQUIDIATION_PRECISION;
        if (totalDscMinted == 0) return type(uint256).max;
        return (collateralAdjustedForThreshold * _PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < _MIN_HEALTH_FACTOR) {
            revert DSCEgine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getTokenAmountFromUsd(address collateral, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[collateral]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * _PRECISION) / (uint256(price) * _ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            address token = _collateralTokens[i];
            uint256 amount = _collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * _ADDITIONAL_FEED_PRECISION) * amount) / _PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return _collateralTokens;
    }
}
