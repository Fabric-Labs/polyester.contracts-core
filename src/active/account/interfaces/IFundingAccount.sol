// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { IZipperEndpoint } from "./IZipperEndpoint.sol";
import { IGuardRegistry } from "../../guard/interfaces/IGuardRegistry.sol";

interface IFundingAccount {
  // ============ STRUCTS ============

  /**
   * @dev Configuration structure for token permissions
   * @param enabled Whether the token is enabled
   * @param deposit Whether deposits are allowed for this token
   * @param withdraw Whether withdrawals are allowed for this token
   */
  struct TokenConfig {
    bool enabled;
    bool deposit;
    bool withdraw;
  }

  // ============ EVENTS ============

  /// @dev Emitted when Zipped Tokens are deposited and credited as Unified Assets
  event Deposit(address indexed fromAccount, address indexed toAccount, address indexed zToken, uint256 zAmount, bytes32 uAssetId, uint256 uAmount);

  /// @dev Emitted when a bridge request deposits tokens into FundingAccount
  event BridgeDepositCredited(
    uint256 indexed requestId,
    address indexed fromAccount,
    address indexed toAccount,
    address zToken,
    uint256 zAmount,
    bytes32 uAssetId,
    uint256 uAmount
  );

  /// @dev Emitted when an account withdraws Zipped Tokens to a local token recipient
  event Withdraw(address indexed fromAccount, address indexed tokenRecipient, address indexed zToken, uint256 zAmount);

  /// @dev Emitted when an account withdraws Zipped Tokens to an external-chain destination
  event WithdrawToChain(
    uint256 indexed requestId,
    uint16 indexed chainId,
    address indexed fromAccount,
    bytes withdrawDestination,
    address zToken,
    uint256 zAmount
  );

  /// @dev Emitted when token configuration is updated
  event ZTokenConfigSet(address indexed zToken, bool enabled, bool deposit, bool withdraw);

  /// @dev Emitted when unified asset configuration is updated
  event UAssetConfigSet(bytes32 indexed uAssetId, bool enabled, bool deposit, bool withdraw);

  /// @dev Emitted when zToken is mapped to a unified asset
  event ZTokenToUAssetSet(address indexed zToken, bytes32 indexed uAssetId);

  /// @dev Emitted when zToken is unmapped from a unified asset
  event ZTokenToUAssetUnset(address indexed zToken);

  /// @dev Emitted when a app is set to the allowed list
  event AllowedAppSet(address indexed app, bool allowed);

  /// @dev Emitted when a uAsset is set to the allowed status for a app
  event AppAllowedUAssetsSet(address indexed app, bytes32 indexed uAssetId, bool allowed);

  /// @dev Emitted when an account's chain-specific external destination allowlist is updated
  event AllowedExternalDestinationsUpdated(address indexed account, uint16 indexed chainId, bytes[] allowedExternalDestinations);

  /// @dev Emitted when an account's internal account allowlist is updated
  event AllowedInternalAccountsUpdated(address indexed account, address[] allowedInternalAccounts);

  /// @dev Emitted when ZipperEndpoint is updated
  event ZipperEndpointSet(address indexed zipperEndpoint);

  /// @dev Emitted when external destination allowlist requirement is updated
  event ExternalDestinationAllowlistRequirementUpdated(address indexed account, bool required);

  /// @dev Emitted when internal account allowlist requirement is updated
  event InternalAccountAllowlistRequirementUpdated(address indexed account, bool required);

  /// @dev Emitted when the guard registry is updated
  event GuardRegistrySet(address indexed guardRegistry);

  /// @dev Emitted when a delegate status is updated
  event DelegateUpdated(address indexed account, address indexed delegate, bool enabled);

  /// @dev Emitted when deposit is paused updated
  event DepositPausedUpdated(address account, bool paused);

  /// @dev Emitted when withdraw is paused updated
  event WithdrawPausedUpdated(address account, bool paused);

  /// @dev Emitted when withdrawToChain is paused updated
  event WithdrawToChainPausedUpdated(address account, bool paused);

  /// @dev Emitted when internal transfer is paused updated
  event InternalTransferPausedUpdated(address account, bool paused);

  /// @dev Emitted when an account's route receiver is set
  event UAssetReceiverSet(address indexed account, address indexed routeReceiver);

  /// @dev Emitted when uAsset receiver fails
  event UAssetReceiverFailed(
    uint256 indexed requestId,
    address indexed zToken,
    address indexed account,
    address routeReceiver,
    bytes32 uAssetId,
    uint256 uAmount,
    bytes reason
  );

  /// @dev Emitted when bridge deposit status is updated
  event BridgeDepositStatusUpdated(address indexed account, bool paused);

  /// @dev Emitted when a Unified Amount is transferred between accounts
  event UAssetTransfer(address indexed fromAccount, address indexed toAccount, bytes32 indexed uAssetId, uint256 uAmount);

  /// @dev Emitted when repeat call is allowed updated
  event RepeatCallAllowedUpdated(address indexed caller, bool allow);

  // ============ ERRORS ============

  /// @dev Thrown when unauthorized access is attempted
  error Forbidden();

  /// @dev Thrown when an invalid amount (zero or negative) is provided
  error InvalidAmount();

  /// @dev Thrown when a zero address is provided where it's not allowed
  error ZeroAddress();

  /// @dev Thrown when attempting to provide a zero ID where it's not allowed
  error ZeroId();

  /// @dev Thrown when zToken withdraw is disabled
  error ZWithdrawDisabled();

  /// @dev Thrown when uAsset withdraw is disabled
  error UWithdrawDisabled();

  /// @dev Thrown when zToken is disabled
  error ZTokenDisabled();

  /// @dev Thrown when zToken deposit is disabled
  error ZDepositDisabled();

  /// @dev Thrown when uAsset is disabled
  error UAssetDisabled();

  /// @dev Thrown when pool has insufficient zToken balance
  error PoolZInsufficientBalance();

  /// @dev Thrown when pool has insufficient uAsset balance
  error PoolUInsufficientBalance();

  /// @dev Thrown when an account has insufficient Unified Amount balance
  error UserUInsufficientBalance();

  /// @dev Thrown when zToken is not mapped to any uAsset
  error ZTokenNotMapped();

  /// @dev Thrown when zToken is already mapped to a uAsset
  error ZTokenAlreadyMapped();

  /// @dev Thrown when app is not allowed
  error AppNotAllowed();

  /// @dev Thrown when attempting to unmap a zToken that still has outstanding balances
  error ZTokenOutstandingBalances();

  /// @dev Thrown when external destination allowlist requirement is active and standard withdraw is attempted
  error ExternalDestinationAllowlistRequired();

  /// @dev Thrown when the provided allowlist entry is invalid
  error InvalidAllowlistEntry();

  /// @dev Thrown when an allowlist exceeds the maximum supported size
  error AllowlistTooLarge();

  /// @dev Thrown when the provided address does not match the allowlist
  error AllowlistMismatch();

  /// @dev Thrown when attempting to enforce allowlist checks without an allowlist
  error NoAllowlistSet();

  /// @dev Thrown when there is nothing to remove
  error NothingToRemove();

  /// @dev Thrown when the normalized zAmount does not match the provided zAmount
  error NormalizedZAmountMismatch();

  /// @dev Thrown when on-chain bridge fee exceeds the account-supplied maxFee cap
  error FeeExceedsMax();

  /// @dev Thrown when deposit is paused
  error DepositPausedError();

  /// @dev Thrown when withdraw is paused
  error WithdrawPausedError();

  /// @dev Thrown when withdrawToChain is paused
  error WithdrawToChainPausedError();

  /// @dev Thrown when internal transfer is paused
  error InternalTransferPausedError();

  /// @dev Thrown when the caller is not a delegate
  error NotDelegateOrOwner();

  /// @dev Thrown when bridge deposit is paused by account
  error BridgeDepositPausedByUser();

  /// @dev Thrown when a delegated transfer targets the source account itself
  error SelfTransferNotAllowed();

  /// @dev Thrown when a protected action is invoked before the guard registry is configured
  error GuardRegistryNotSet();

  // ============ VIEW FUNCTIONS ============

  /// @dev Pool balances: zToken address => balance amount
  function poolZBalances(address zToken) external view returns (uint256);

  /// @dev Pool balances: uAsset id => balance amount
  function poolUBalances(bytes32 uAssetId) external view returns (uint256);

  /// @dev Zipper bridge endpoint used for withdraw-to-chain
  function zipperEndpoint() external view returns (IZipperEndpoint);

  /// @dev Account available balances (not locked by any app): account address => Unified Asset Id => Unified Amount
  function accountUBalances(address account, bytes32 uAssetId) external view returns (uint256);

  /// @dev Registry used to validate guard approvals for protected actions
  function guardRegistry() external view returns (IGuardRegistry);

  /// @dev App-isolated frozen balances (locked by specific apps): app address => account address => Unified Asset Id => Unified Amount
  function appUBalances(address app, address account, bytes32 uAssetId) external view returns (uint256);

  /// @dev Mapping from zToken to its corresponding unified asset: zToken address => uAsset id
  function zTokenToUAsset(address zToken) external view returns (bytes32);

  /// @dev zToken configuration mapping: zToken address => TokenConfig
  function getZTokenConfig(address zToken) external view returns (TokenConfig memory);

  /// @dev uAsset configuration mapping: uAsset id => TokenConfig
  function getUAssetConfig(bytes32 uAssetId) external view returns (TokenConfig memory);

  /// @dev Reverts when a required internal account allowlist does not permit the destination
  function validateInternalAccountAllowlist(address fromAccount, address toAccount) external view;

  /**
   * @dev Generates a unique ID for a unified asset. The id is the lowercase of the name.
   * @param uAssetName The name of the unified asset
   * @return The unique ID for the unified asset and the lowercase name
   */
  function genUAssetId(string memory uAssetName) external pure returns (bytes32, string memory);

  // ============ CORE OPERATIONS ============

  /// @dev Deposits Zipped Tokens into FundingAccount and credits the caller account with Unified Assets
  function deposit(address zToken, uint256 zAmount) external;

  /// @dev Withdraws Zipped Tokens from FundingAccount to the caller account
  function withdraw(address zToken, uint256 zAmount) external;

  /// @dev Withdraws Zipped Tokens from FundingAccount to a local token recipient
  function withdrawTo(address tokenRecipient, address zToken, uint256 zAmount) external;

  /// @dev Transfers a Unified Amount from the caller account to another account
  function transfer(address toAccount, bytes32 uAssetId, uint256 uAmount) external;

  /// @dev Transfers a Unified Amount from an account to another account on behalf of that account
  function transferFrom(address fromAccount, address toAccount, bytes32 uAssetId, uint256 uAmount) external;

  /// @dev Sets the bridge deposit pause status for the caller
  function setBridgeDepositPause(bool paused) external;

  /// @dev Enables/disables external destination allowlist requirement; disabling requires guard approval
  function setExternalDestinationAllowlistRequired(bool required, IGuardRegistry.Approval calldata guardSigIfFalse) external;

  /// @dev Enables/disables internal account allowlist requirement; disabling requires guard approval
  function setInternalAccountAllowlistRequired(bool required, IGuardRegistry.Approval calldata guardSigIfFalse) external;

  /// @dev Freezes an account balance for app operations and credits the frozen balance to another account. Called by allowed apps.
  function appFreeze(address fromAccount, address toAccount, bytes32 uAssetId, uint256 uAmount) external;

  /// @dev Unfreezes an account balance and transfers it to another account. Called by allowed apps.
  function appUnfreeze(address fromAccount, address toAccount, bytes32 uAssetId, uint256 uAmount) external;

  /// @dev Withdraws Zipped Tokens directly to a destination chain via Zipper Bridge on behalf of an account. Called by allowed apps.
  function appWithdrawToChain(address account, IZipperEndpoint.WithdrawRequest calldata request) external returns (uint256 requestId);

  /// @dev Adds multiple destinations to the caller's chain-specific external destination allowlist using a guard-approved path
  function addAllowedExternalDestinations(uint16 chainId, bytes[] calldata destinations, IGuardRegistry.Approval calldata approval) external;

  /// @dev Removes multiple destinations from the caller's chain-specific external destination allowlist using a guard-approved path
  function removeAllowedExternalDestinations(uint16 chainId, bytes[] calldata destinations, IGuardRegistry.Approval calldata approval) external;

  /// @dev Adds multiple accounts to the caller's internal account allowlist using a guard-approved path
  function addAllowedInternalAccounts(address[] calldata accounts, IGuardRegistry.Approval calldata approval) external;

  /// @dev Removes multiple accounts from the caller's internal account allowlist using a guard-approved path
  function removeAllowedInternalAccounts(address[] calldata accounts, IGuardRegistry.Approval calldata approval) external;

  /// @dev Sets delegate status for the caller
  function setDelegate(address delegate, bool enabled) external;

  /// @dev Allows a delegate to renounce delegation granted by an account
  function renounceDelegate(address account) external;

  /// @dev Withdraws Zipped Tokens from FundingAccount on behalf of an account, sending tokens to the account
  function withdrawFrom(address fromAccount, address zToken, uint256 zAmount) external;

  /// @dev Withdraws Zipped Tokens directly to a destination chain via Zipper Bridge on behalf of an account
  function withdrawToChainFrom(address fromAccount, IZipperEndpoint.WithdrawRequest calldata request) external;

  // ============ CONFIGURATION FUNCTIONS ============

  /**
   * @dev Sets the guard registry used by protected actions
   * @param registry The address of the guard registry contract
   */
  function setGuardRegistry(address registry) external;

  /**
   * @dev Configures deposit and withdrawal permissions for a zToken
   * @param token The address of the token to configure
   * @param enabled Whether the token should be enabled
   * @param depositAllowed Whether deposits should be allowed for this token
   * @param withdrawAllowed Whether withdrawals should be allowed for this token
   */
  function configZToken(address token, bool enabled, bool depositAllowed, bool withdrawAllowed) external;

  /**
   * @dev Configures deposit and withdrawal permissions for a unified asset
   * @param uAssetName The name of the unified asset to configure
   * @param enabled Whether the unified asset should be enabled
   * @param depositAllowed Whether deposits should be allowed for this asset
   * @param withdrawAllowed Whether withdrawals should be allowed for this asset
   */
  function configUAsset(string memory uAssetName, bool enabled, bool depositAllowed, bool withdrawAllowed) external;

  /**
   * @dev Maps a zToken to a unified asset
   * @param zToken The address of the zToken to map
   * @param uAssetId The ID of the unified asset to map to
   */
  function mapZTokenToUAsset(address zToken, bytes32 uAssetId) external;

  /**
   * @dev Unmaps a zToken from its unified asset
   * @param zToken The address of the zToken to unmap
   */
  function unmapZTokenFromUAsset(address zToken) external;

  /**
   * @dev Sets the deposit pause state
   * @param paused Whether to pause deposits
   */
  function setDepositPause(bool paused) external;

  /**
   * @dev Sets the withdraw pause state
   * @param paused Whether to pause withdrawals
   */
  function setWithdrawPause(bool paused) external;

  /**
   * @dev Sets the withdrawToChain pause state
   * @param paused Whether to pause withdrawToChain
   */
  function setWithdrawToChainPause(bool paused) external;

  /**
   * @dev Sets the internal transfer pause state
   * @param paused Whether to pause internal transfers
   */
  function setInternalTransferPause(bool paused) external;
}
