/**
 * @title: DyDx wrapper
 * @summary: Used for interacting with DyDx. Has
 *           a common interface with all other protocol wrappers.
 *           This contract holds assets only during a tx, after tx it should be empty
 * @author: William Bergamo, idle.finance
 */
pragma solidity 0.5.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/ILendingProtocol.sol";
import "../interfaces/IInterestSetter.sol";
import "../interfaces/DyDxStructs.sol";
import "../interfaces/DyDx.sol";
import "./yxToken.sol";

contract IdleDyDx is ILendingProtocol, DyDxStructs, Ownable {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  uint256 public marketId;
  uint256 public secondsInAYear;
  // underlying token (token eg DAI) address
  address public underlying;
  address public token;
  address public idleToken;
  address public dydxAddressesProvider = address(0x1E0447b19BB6EcFdAe1e4AE1694b0C3659614e4e);
  /**
   * @param _underlying : underlying token (eg DAI) address
   * @param _token : protocol token (eg cDAI) address
   * @param _marketId : dydx market id
   */
  constructor(address _token, address _underlying, uint256 _marketId)
    public {
    require(_underlying != address(0), '_underlying addr is 0');

    secondsInAYear = 31536000; // 60 * 60 * 24 * 365
    underlying = _underlying;
    token = _token;
    marketId = _marketId; // 0, ETH, (1 SAI not available), 2 USDC, 3 DAI
  }

  /**
   * Throws if called by any account other than IdleToken contract.
   */
  modifier onlyIdle() {
    require(msg.sender == idleToken, "Ownable: caller is not IdleToken contract");
    _;
  }

  // onlyOwner
  /**
   * sets idleToken address
   * NOTE: can be called only once. It's not on the constructor because we are deploying this contract
   *       after the IdleToken contract
   * @param _idleToken : idleToken address
   */
  function setIdleToken(address _idleToken)
    external onlyOwner {
      require(idleToken == address(0), "idleToken addr already set");
      require(_idleToken != address(0), "_idleToken addr is 0");
      idleToken = _idleToken;
  }

  /**
   * sets dydxAddressesProvider address
   * @param _dydxAddressesProvider : dydxAddressesProvider address
   */
  function setDydxAddressesProvider(address _dydxAddressesProvider)
    external onlyOwner {
      require(_dydxAddressesProvider != address(0), "_dydxAddressesProvider addr is 0");
      dydxAddressesProvider = _dydxAddressesProvider;
  }
  /**
   * sets secondsInAYear address
   * @param _secondsInAYear : secondsInAYear address
   */
  function setSecondsInAYear(uint256 _secondsInAYear)
    external onlyOwner {
      require(_secondsInAYear != 0, "_secondsInAYear addr is 0");
      secondsInAYear = _secondsInAYear;
  }
  // end onlyOwner

  /**
   * Calculate next supply rate for DyDx, given an `_amount` supplied (last array param)
   * and all other params supplied. See `info_compound.md` for more info
   * on calculations.
   *
   * @param params : array with all params needed for calculation (see below)
   * @return : yearly net rate
   */
  function nextSupplyRateWithParams(uint256[] calldata params)
    external view
    returns (uint256) {
      return nextSupplyRate(params[params.length - 1]);
  }

  /**
   * Calculate next supply rate for DyDx, given an `_amount` supplied
   *
   * @param _amount : new underlying amount supplied (eg DAI)
   * @return : yearly net rate eg (5.01 %)
   */
  function nextSupplyRate(uint256 _amount)
    public view
    returns (uint256) {
      DyDx dydx = DyDx(dydxAddressesProvider);
      (uint256 borrow, uint256 supply) = dydx.getMarketTotalPar(marketId);
      (uint256 borrowIndex, uint256 supplyIndex) = dydx.getMarketCurrentIndex(marketId);
      borrow = borrow.mul(borrowIndex).div(10**18);
      supply = supply.mul(supplyIndex).div(10**18);
      uint256 usage = borrow.mul(10**18).div(supply.add(_amount));
      uint256 borrowRatePerSecond;
      if (_amount == 0) {
        borrowRatePerSecond = dydx.getMarketInterestRate(marketId);
      } else {
        // Here we are calc the new borrow rate when we supply `_amount` liquidity
        borrowRatePerSecond = IInterestSetter(dydx.getMarketInterestSetter(marketId)).getInterestRate(
          underlying,
          borrow,
          supply.add(_amount)
        );
      }
      uint256 aprBorrow = borrowRatePerSecond.mul(secondsInAYear);
      return aprBorrow.mul(usage).div(10**18).mul(dydx.getEarningsRate()).mul(100).div(10**18);
  }

  /**
   * @return current price of yxToken in underlying
   */
  function getPriceInToken()
    external view
    returns (uint256) {
    return yxToken(token).price();
  }

  /**
   * @return apr : current yearly net rate
   */
  function getAPR()
    external view
    returns (uint256) {
      return nextSupplyRate(0);
  }

  /**
   * Gets all underlying tokens in this contract and mints yxTokens
   * tokens are then transferred to msg.sender
   * NOTE: underlying tokens needs to be sent here before calling this
   *
   * @return yxTokens minted
   */
  function mint()
    external onlyIdle
    returns (uint256 yxTokens) {
      uint256 balance = IERC20(underlying).balanceOf(address(this));
      if (balance == 0) {
        return yxTokens;
      }
      // approve the transfer to yxToken contract
      IERC20(underlying).safeIncreaseAllowance(token, balance);
      // get a handle for the corresponding yxToken contract
      yxToken yxToken = yxToken(token);
      // mint the yxTokens
      yxToken.mint(balance);
      // yxTokens are now in this contract
      yxTokens = IERC20(token).balanceOf(address(this));
      // transfer them to the caller
      IERC20(token).safeTransfer(msg.sender, yxTokens);
  }

  /**
   * Gets all yxTokens in this contract and redeems underlying tokens.
   * underlying tokens are then transferred to `_account`
   * NOTE: yxTokens needs to be sent here before calling this
   *
   * @return underlying tokens redeemd
   */
  function redeem(address _account)
    external onlyIdle
    returns (uint256 tokens) {
      // Funds needs to be sent here before calling this
      // redeem all underlying sent in this contract
      tokens = yxToken(token).redeem(IERC20(token).balanceOf(address(this)), _account);
  }

  function availableLiquidity() external view returns (uint256) {
    return IERC20(underlying).balanceOf(dydxAddressesProvider);
  }
}
