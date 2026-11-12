// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IFundingAccount.sol";
import "./interfaces/IZipperEndpoint.sol";
import "./interfaces/IZipperFactoryFee.sol";
import "./interfaces/IUAssetReceiver.sol";
import "../bridge/interfaces/IProgramReceiver.sol";
import "../guard/interfaces/IGuardRegistry.sol";
import "../utils/RepeatCallGuard.sol";
import "../libs/MathLib.sol";
import "../libs/StringLib.sol";

contract FundingAccount is IFundingAccount, IProgramReceiver, RepeatCallGuard, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  // ============ CONSTANTS ============

  /// @dev Role identifier for editors who can configure tokens and pools
  bytes32 public constant EDITOR_ROLE = keccak256("EDITOR_ROLE");

  /// @dev Role identifier for minters who can call onTokensMinted
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @dev Decimal places for uAssets
  uint8 public constant U_DECIMALS = 18;

  uint8 public constant WITHDRAW_ORIGIN_FUNDING_ACCOUNT = 2;
  uint8 public constant WITHDRAW_ORIGIN_TRADING_GATEWAY = 3;

  /// @dev Maximum external destination allowlist entries per (account, chainId) to keep operations bounded
  uint256 public constant MAX_ALLOWED_EXTERNAL_DESTINATIONS = 50;

  /// @dev Maximum internal account allowlist entries per account to keep operations bounded
  uint256 public constant MAX_ALLOWED_INTERNAL_ACCOUNTS = 200;

  /// @dev Semantic selector used for guard-approved external destination allowlist requirement changes
  bytes4 private constant SET_EXTERNAL_DESTINATION_ALLOWLIST_REQUIRED_ACTION_SELECTOR =
    bytes4(keccak256("setExternalDestinationAllowlistRequired(bool)"));

  /// @dev Semantic selector used for guard-approved internal account allowlist requirement changes
  bytes4 private constant SET_INTERNAL_ACCOUNT_ALLOWLIST_REQUIRED_ACTION_SELECTOR = bytes4(keccak256("setInternalAccountAllowlistRequired(bool)"));

  /// @dev Semantic selector used for guard-approved external destination allowlist additions
  bytes4 private constant ADD_ALLOWED_EXTERNAL_DESTINATIONS_ACTION_SELECTOR = bytes4(keccak256("addAllowedExternalDestinations(uint16,bytes[])"));

  /// @dev Semantic selector used for guard-approved external destination allowlist removals
  bytes4 private constant REMOVE_ALLOWED_EXTERNAL_DESTINATIONS_ACTION_SELECTOR =
    bytes4(keccak256("removeAllowedExternalDestinations(uint16,bytes[])"));

  /// @dev Semantic selector used for guard-approved internal account allowlist additions
  bytes4 private constant ADD_ALLOWED_INTERNAL_ACCOUNTS_ACTION_SELECTOR = bytes4(keccak256("addAllowedInternalAccounts(address[])"));

  /// @dev Semantic selector used for guard-approved internal account allowlist removals
  bytes4 private constant REMOVE_ALLOWED_INTERNAL_ACCOUNTS_ACTION_SELECTOR = bytes4(keccak256("removeAllowedInternalAccounts(address[])"));

  // ============ BALANCES ============

  /// @dev Pool zToken balances: pool address => zToken address => balance amount
  mapping(address => uint256) public poolZBalances;

  /// @dev Pool uAsset balances: pool address => uAsset id => balance amount
  mapping(bytes32 => uint256) public poolUBalances;

  /// @dev Account available balances (not locked by any app): account address => Unified Asset Id => Unified Amount
  mapping(address => mapping(bytes32 => uint256)) public accountUBalances;

  /// @dev App-isolated frozen balances (locked by specific apps): app address => account address => Unified Asset Id => Unified Amount
  mapping(address => mapping(address => mapping(bytes32 => uint256))) public appUBalances;

  // ============ STATE VARIABLES ============

  /// @dev zToken configuration mapping: zToken address => TokenConfig
  mapping(address => TokenConfig) public zTokenConfigs;

  /// @dev Mapping to track enabled unified assets: uAsset id => enabled status
  mapping(bytes32 => TokenConfig) private uAssetConfigs;

  /// @dev Mapping from zToken to its corresponding unified asset: zToken address => uAsset id
  mapping(address => bytes32) public zTokenToUAsset;

  // ============ APPS MANAGEMENT ============

  /// @dev Mapping to track allowed apps: app address => allowed status
  mapping(address => bool) public allowedApps;

  /// @dev Mapping to track which uAssets each app is allowed to work with: app address => uAsset id => allowed status
  mapping(address => mapping(bytes32 => bool)) public appAllowedUAssets;

  // ============ WHITELIST & BRIDGE ============

  /// @dev Zipper Endpoint contract address
  IZipperEndpoint public zipperEndpoint;

  /// @dev Delegate mapping: account address => delegate address => is delegate
  mapping(address => mapping(address => bool)) public isDelegate;

  /// @dev Whether deposits are paused
  bool public depositPaused;

  /// @dev Whether withdrawals are paused
  bool public withdrawPaused;

  /// @dev Whether withdrawToChain is paused
  bool public withdrawToChainPaused;

  /// @dev Whether internal transfers are paused
  bool public internalTransferPaused;

  /// @dev Mapping to track an account's preferred route receiver contract
  mapping(address => address) public accountRouteReceiver;

  /// @dev Mapping to track if an account paused bridge deposits
  mapping(address => bool) public accountBridgeDepositPaused;

  /// @dev Internal account allowlist: account address => allowed Polyester smart accounts for internal transfers
  mapping(address => address[]) public allowedInternalAccounts;

  /// @dev Registry used to validate guard approvals for protected account actions
  IGuardRegistry public guardRegistry;

  /// @dev External destination allowlist: account address => destination chain id => allowed withdrawal destinations
  mapping(address => mapping(uint16 => bytes[])) public allowedExternalDestinations;

  /// @dev Whether external-chain withdrawals must pass external destination allowlist checks
  mapping(address => bool) public externalDestinationAllowlistRequired;

  /// @dev Whether internal transfers must pass internal account allowlist checks
  mapping(address => bool) public internalAccountAllowlistRequired;

  // ============ MODIFIERS ============

  /**
   * @dev Ensures deposit is not paused
   */
  modifier whenDepositNotPaused() {
    if (depositPaused) revert DepositPausedError();
    _;
  }

  /**
   * @dev Ensures withdraw is not paused
   */
  modifier whenWithdrawNotPaused() {
    if (withdrawPaused) revert WithdrawPausedError();
    _;
  }

  /**
   * @dev Ensures withdrawToChain is not paused
   */
  modifier whenWithdrawToChainNotPaused() {
    if (withdrawToChainPaused) revert WithdrawToChainPausedError();
    _;
  }

  /**
   * @dev Ensures internal transfer is not paused
   */
  modifier whenInternalTransferNotPaused() {
    if (internalTransferPaused) revert InternalTransferPausedError();
    _;
  }

  /**
   * @dev Ensures only allowed apps can call the function and the specified uAsset is registered for the app
   * @param uAssetId The uAsset id to verify against the app
   */
  modifier onlyAllowedApp(bytes32 uAssetId) {
    if (!allowedApps[msg.sender] || !appAllowedUAssets[msg.sender][uAssetId]) revert Forbidden();
    _;
  }

  /**
   * @dev Ensures the amount is greater than zero
   * @param amount The amount to validate
   */
  modifier validAmount(uint256 amount) {
    if (amount == 0) revert InvalidAmount();
    _;
  }

  // ============ CONSTRUCTOR & INITIALIZATION ============

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Initializes the contract with default roles and security settings
   * @notice This function can only be called once during contract deployment
   */
  function FundingAccountInit() external initializer {
    __ReentrancyGuard_init();
    __AccessControl_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(EDITOR_ROLE, sender_);
  }

  // ============ VIEW FUNCTIONS ============

  /// @dev zToken configuration mapping: zToken address => TokenConfig
  function getZTokenConfig(address zToken) external view returns (TokenConfig memory) {
    return zTokenConfigs[zToken];
  }

  /// @dev uAsset configuration mapping: uAsset id => TokenConfig
  function getUAssetConfig(bytes32 uAssetId) external view returns (TokenConfig memory) {
    return uAssetConfigs[uAssetId];
  }

  /**
   * @dev Generates a unique ID for a unified asset. The id is the lowercase of the name.
   * @param uAssetName The name of the unified asset
   * @return uAssetId The unique ID for the unified asset
   * @return lowerCaseName The lowercase name of the unified asset
   */
  function genUAssetId(string memory uAssetName) external pure returns (bytes32 uAssetId, string memory lowerCaseName) {
    lowerCaseName = StringLib.toLowerCase(uAssetName);
    uAssetId = keccak256(abi.encodePacked(lowerCaseName));
  }

  // ============ PROGRAM RECEIVER FUNCTIONS ============

  /**
   * @dev Handles minting of zTokens and updates the balances of the user
   * @notice Only addresses with MINTER_ROLE can call this function
   */
  function onTokensMinted(
    uint256 requestId,
    uint16,
    address zToken,
    address creditedAccount,
    uint256 zAmount
  ) external override nonReentrant onlyRole(MINTER_ROLE) whenDepositNotPaused returns (bool accepted, address finalRouteReceiver) {
    if (accountBridgeDepositPaused[creditedAccount]) revert BridgeDepositPausedByUser();
    (, bytes32 uAssetId, uint256 uAmount) = _deposit(zToken, creditedAccount, zAmount, false);

    // Auto-deposit to configured route receiver if enabled
    finalRouteReceiver = address(this);
    bool creditedToReceiver;
    address routeReceiver = accountRouteReceiver[creditedAccount];
    if (routeReceiver != address(0)) {
      // Receiver must still be an allowed app (double check in case it was removed from allowedApps)
      if (allowedApps[routeReceiver] && appAllowedUAssets[routeReceiver][uAssetId]) {
        try IUAssetReceiver(routeReceiver).depositForRequest(requestId, creditedAccount, uAssetId, uAmount) returns (
          address returnedFinalRouteReceiver
        ) {
          finalRouteReceiver = returnedFinalRouteReceiver == address(0) ? routeReceiver : returnedFinalRouteReceiver;
          creditedToReceiver = true;
        } catch (bytes memory reason) {
          emit UAssetReceiverFailed(requestId, zToken, creditedAccount, routeReceiver, uAssetId, uAmount, reason);
        }
      }
    }
    if (!creditedToReceiver) {
      emit BridgeDepositCredited(requestId, msg.sender, creditedAccount, zToken, zAmount, uAssetId, uAmount);
    }
    return (true, finalRouteReceiver);
  }

  // ============ PUBLIC FUNCTIONS ============

  /**
   * @dev Deposits zTokens into the exchange and credits the user with zTokens
   * @param zToken The address of the zToken to deposit
   * @param zAmount The amount of zTokens to deposit
   * Emits a {Deposit} event
   */
  function deposit(address zToken, uint256 zAmount) external nonReentrant nonRepeat whenDepositNotPaused {
    _deposit(zToken, msg.sender, zAmount, true);
  }

  /**
   * @notice The amount transferred to the user is the normalized value after decimal conversion
   * and can be less than `zAmount` when truncation occurs.
   * @dev Withdraws zTokens from the exchange and sends zTokens to the user
   * @param zToken The address of the zToken to withdraw
   * @param zAmount The amount of zTokens to withdraw
   *
   * Requirements:
   * - Token must be configured for withdrawals
   * - User must have sufficient balance
   *
   * Emits a {Withdraw} event
   */
  function withdraw(address zToken, uint256 zAmount) external nonReentrant nonRepeat whenWithdrawNotPaused {
    _withdraw(msg.sender, msg.sender, zToken, zAmount);
  }

  /**
   * @dev Withdraws zTokens from the FundingAccount and sends them to a local token recipient.
   *      The caller is the account whose balances are debited.
   * @param tokenRecipient The local token recipient address
   * @param zToken The address of the zToken to withdraw
   * @param zAmount The amount of zTokens to withdraw
   */
  function withdrawTo(address tokenRecipient, address zToken, uint256 zAmount) external nonReentrant whenWithdrawNotPaused {
    if (tokenRecipient == address(0)) revert ZeroAddress();
    _withdraw(msg.sender, tokenRecipient, zToken, zAmount);
  }

  /**
   * @dev Withdraws zTokens from the FundingAccount on behalf of an account.
   *      Can be called by the account itself or a delegate. Tokens are sent to the account.
   * @param fromAccount The account to withdraw from
   * @param zToken The address of the zToken to withdraw
   * @param zAmount The amount of zTokens to withdraw
   */
  function withdrawFrom(address fromAccount, address zToken, uint256 zAmount) external nonReentrant whenWithdrawNotPaused {
    if (msg.sender != fromAccount && !isDelegate[fromAccount][msg.sender]) revert NotDelegateOrOwner();
    _withdraw(fromAccount, fromAccount, zToken, zAmount);
  }

  function _withdraw(address fromAccount, address tokenRecipient, address zToken, uint256 zAmount) internal validAmount(zAmount) {
    if (externalDestinationAllowlistRequired[fromAccount]) revert ExternalDestinationAllowlistRequired();

    (bytes32 uAssetId, uint256 uAmount, uint256 normalizedZAmount) = _resolveWithdrawAmounts(zToken, zAmount);
    _deductPoolZBalance(zToken, normalizedZAmount);
    _deductUserAndPoolUBalance(fromAccount, uAssetId, uAmount);

    // Transfer zTokens to the token recipient
    IERC20(zToken).safeTransfer(tokenRecipient, normalizedZAmount);

    emit Withdraw(fromAccount, tokenRecipient, zToken, normalizedZAmount);
  }

  /**
   * @dev Withdraws zTokens directly to a destination chain via Zipper Bridge.
   *      Enforces allowlist check if set. Handles fee payment.
   * @param request The withdrawal request structure containing all details
   */
  function withdrawToChain(IZipperEndpoint.WithdrawRequest calldata request) external nonReentrant whenWithdrawToChainNotPaused {
    _withdrawToChain(msg.sender, request, WITHDRAW_ORIGIN_FUNDING_ACCOUNT, address(this));
  }

  /**
   * @dev Withdraws zTokens directly to a destination chain via Zipper Bridge on behalf of an account.
   *      Can be called by the account itself or a delegate.
   * @param fromAccount The account to withdraw from
   * @param request The withdrawal request structure containing all details
   */
  function withdrawToChainFrom(
    address fromAccount,
    IZipperEndpoint.WithdrawRequest calldata request
  ) external nonReentrant whenWithdrawToChainNotPaused {
    if (msg.sender != fromAccount && !isDelegate[fromAccount][msg.sender]) revert NotDelegateOrOwner();
    _withdrawToChain(fromAccount, request, WITHDRAW_ORIGIN_FUNDING_ACCOUNT, address(this));
  }

  /**
   * @dev Transfers uAsset from the caller account to another account.
   *      Operates on available balance. If internal account allowlist is required, the toAccount must be in the caller's allowlist.
   * @param toAccount The account to credit
   * @param uAssetId The uAsset ID to transfer
   * @param uAmount The amount to transfer
   */
  function transfer(address toAccount, bytes32 uAssetId, uint256 uAmount) external override nonReentrant whenInternalTransferNotPaused {
    _transfer(msg.sender, toAccount, uAssetId, uAmount);
  }

  /**
   * @dev Transfers uAsset from an account to another account on behalf of that account.
   *      Can be called by the account itself or a delegate.
   *      If internal account allowlist is required, the toAccount must be in fromAccount's allowlist.
   * @param fromAccount The account to transfer from
   * @param toAccount The account to credit
   * @param uAssetId The uAsset ID to transfer
   * @param uAmount The amount to transfer
   */
  function transferFrom(
    address fromAccount,
    address toAccount,
    bytes32 uAssetId,
    uint256 uAmount
  ) external nonReentrant whenInternalTransferNotPaused {
    if (msg.sender != fromAccount && !isDelegate[fromAccount][msg.sender]) revert NotDelegateOrOwner();
    if (msg.sender != fromAccount && fromAccount == toAccount) revert SelfTransferNotAllowed();
    _transfer(fromAccount, toAccount, uAssetId, uAmount);
  }

  function _transfer(address fromAccount, address toAccount, bytes32 uAssetId, uint256 uAmount) internal {
    if (toAccount == address(0)) revert ZeroAddress();
    if (uAmount == 0) revert InvalidAmount();
    _validateInternalAccountAllowlist(fromAccount, toAccount);

    if (accountUBalances[fromAccount][uAssetId] < uAmount) revert UserUInsufficientBalance();

    accountUBalances[fromAccount][uAssetId] -= uAmount;
    accountUBalances[toAccount][uAssetId] += uAmount;

    emit UAssetTransfer(fromAccount, toAccount, uAssetId, uAmount);
  }

  function _withdrawToChain(
    address fromAccount,
    IZipperEndpoint.WithdrawRequest calldata request,
    uint8 origin,
    address originContract
  ) internal returns (uint256 requestId) {
    if (address(zipperEndpoint) == address(0)) revert ZeroAddress();

    _validateExternalDestinationAllowlist(fromAccount, request.chainId, request.withdrawDestination);

    (bytes32 uAssetId, uint256 uAmount, uint256 normalizedZAmount) = _resolveWithdrawAmounts(request.zToken, request.zAmount);
    if (normalizedZAmount != request.zAmount) revert NormalizedZAmountMismatch();

    address feeFactoryAddr = zipperEndpoint.feeFactory();
    if (feeFactoryAddr == address(0)) revert ZeroAddress();

    uint256 feeZ = IZipperFactoryFee(feeFactoryAddr).getFee(request.chainId, request.zToken);
    if (feeZ > request.maxFee) revert FeeExceedsMax();
    if (request.zAmount <= feeZ) revert InvalidAmount();

    _deductPoolZBalance(request.zToken, request.zAmount);
    _deductUserAndPoolUBalance(fromAccount, uAssetId, uAmount);

    IERC20(request.zToken).forceApprove(address(zipperEndpoint), request.zAmount);
    requestId = zipperEndpoint.reqWithdrawZTokenFrom(request, fromAccount, origin, originContract);
    IERC20(request.zToken).forceApprove(address(zipperEndpoint), 0);

    if (origin == WITHDRAW_ORIGIN_FUNDING_ACCOUNT) {
      emit WithdrawToChain(requestId, request.chainId, fromAccount, request.withdrawDestination, request.zToken, request.zAmount);
    }
  }

  /**
   * @dev Sets the route receiver for the caller account
   * @param routeReceiver The route receiver contract. Must be an allowed app or address(0) to disable.
   */
  function setUAssetReceiver(address routeReceiver) external {
    if (routeReceiver != address(0) && !allowedApps[routeReceiver]) revert AppNotAllowed();
    accountRouteReceiver[msg.sender] = routeReceiver;
    emit UAssetReceiverSet(msg.sender, routeReceiver);
  }

  /**
   * @dev Sets the bridge deposit pause status for the caller
   * @param paused Whether to pause bridge deposits
   */
  function setBridgeDepositPause(bool paused) external {
    accountBridgeDepositPaused[msg.sender] = paused;
    emit BridgeDepositStatusUpdated(msg.sender, paused);
  }

  // ============ WHITELIST FUNCTIONS ============

  /**
   * @dev Enables or disables external destination allowlist requirement for chain withdrawals.
   *      Disabling (required=false) requires guard approval.
   * @param required Whether external destination allowlist checks are required
   * @param guardSigIfFalse Guard approval payload required only when required=false
   */
  function setExternalDestinationAllowlistRequired(bool required, IGuardRegistry.Approval calldata guardSigIfFalse) external {
    if (!required) {
      _consumeApproval(msg.sender, SET_EXTERNAL_DESTINATION_ALLOWLIST_REQUIRED_ACTION_SELECTOR, keccak256(abi.encode(required)), guardSigIfFalse);
    }

    _setExternalDestinationAllowlistRequired(msg.sender, required);
  }

  /**
   * @dev Enables or disables internal account allowlist requirement for internal transfers.
   *      Disabling (required=false) requires guard approval.
   * @param required Whether internal account allowlist checks are required
   * @param guardSigIfFalse Guard approval payload required only when required=false
   */
  function setInternalAccountAllowlistRequired(bool required, IGuardRegistry.Approval calldata guardSigIfFalse) external {
    if (!required) {
      _consumeApproval(msg.sender, SET_INTERNAL_ACCOUNT_ALLOWLIST_REQUIRED_ACTION_SELECTOR, keccak256(abi.encode(required)), guardSigIfFalse);
    }

    _setInternalAccountAllowlistRequired(msg.sender, required);
  }

  /**
   * @dev Adds multiple destinations to the caller's chain-specific external destination allowlist using a guard-approved path.
   * @param chainId The destination chain id for the allowlist entries
   * @param destinations The list of destination addresses to allow
   * @param approval The approval payload for this protected action
   */
  function addAllowedExternalDestinations(uint16 chainId, bytes[] calldata destinations, IGuardRegistry.Approval calldata approval) external {
    _consumeApproval(msg.sender, ADD_ALLOWED_EXTERNAL_DESTINATIONS_ACTION_SELECTOR, keccak256(abi.encode(chainId, destinations)), approval);
    _addAllowedExternalDestinations(msg.sender, chainId, destinations);
  }

  /**
   * @dev Removes multiple destinations from the caller's chain-specific external destination allowlist using a guard-approved path.
   * @param chainId The destination chain id for the allowlist entries
   * @param destinations The list of destination addresses to remove
   * @param approval The approval payload for this protected action
   */
  function removeAllowedExternalDestinations(uint16 chainId, bytes[] calldata destinations, IGuardRegistry.Approval calldata approval) external {
    _consumeApproval(msg.sender, REMOVE_ALLOWED_EXTERNAL_DESTINATIONS_ACTION_SELECTOR, keccak256(abi.encode(chainId, destinations)), approval);
    _removeAllowedExternalDestinations(msg.sender, chainId, destinations);
  }

  /**
   * @dev Adds multiple accounts to the caller's internal account allowlist using a guard-approved path.
   * @param accounts The list of internal accounts to allow
   * @param approval The approval payload for this protected action
   */
  function addAllowedInternalAccounts(address[] calldata accounts, IGuardRegistry.Approval calldata approval) external {
    _consumeApproval(msg.sender, ADD_ALLOWED_INTERNAL_ACCOUNTS_ACTION_SELECTOR, keccak256(abi.encode(accounts)), approval);
    _addAllowedInternalAccounts(msg.sender, accounts);
  }

  /**
   * @dev Removes multiple accounts from the caller's internal account allowlist using a guard-approved path.
   * @param accounts The list of internal accounts to remove
   * @param approval The approval payload for this protected action
   */
  function removeAllowedInternalAccounts(address[] calldata accounts, IGuardRegistry.Approval calldata approval) external {
    _consumeApproval(msg.sender, REMOVE_ALLOWED_INTERNAL_ACCOUNTS_ACTION_SELECTOR, keccak256(abi.encode(accounts)), approval);
    _removeAllowedInternalAccounts(msg.sender, accounts);
  }

  /**
   * @dev Sets delegate status for the caller.
   *      Delegates can withdraw funds on behalf of the user.
   * @param delegate The address to update as a delegate
   * @param enabled Whether the delegate should be enabled
   */
  function setDelegate(address delegate, bool enabled) external {
    if (delegate == address(0)) revert ZeroAddress();
    _setDelegate(msg.sender, delegate, enabled);
  }

  /**
   * @dev Allows a delegate to renounce delegation granted by an account.
   * @param account The account that granted delegation to the caller
   */
  function renounceDelegate(address account) external {
    if (account == address(0)) revert ZeroAddress();
    _setDelegate(account, msg.sender, false);
  }

  // ============ EDITOR FUNCTIONS ============

  function setAllowRepeatCall(address sender, bool allow) external onlyRole(EDITOR_ROLE) {
    _allowRepeatCall[sender] = allow;
    emit RepeatCallAllowedUpdated(sender, allow);
  }

  /**
   * @dev Sets the guard registry used by protected account actions.
   * @param registry The address of the guard registry contract
   */
  function setGuardRegistry(address registry) external onlyRole(EDITOR_ROLE) {
    if (registry == address(0)) revert ZeroAddress();
    guardRegistry = IGuardRegistry(registry);
    emit GuardRegistrySet(registry);
  }

  /**
   * @dev Sets the deposit pause state
   * @param paused Whether to pause deposits
   */
  function setDepositPause(bool paused) external onlyRole(EDITOR_ROLE) {
    depositPaused = paused;
    emit DepositPausedUpdated(msg.sender, depositPaused);
  }

  /**
   * @dev Sets the withdraw pause state
   * @param paused Whether to pause withdrawals
   */
  function setWithdrawPause(bool paused) external onlyRole(EDITOR_ROLE) {
    withdrawPaused = paused;
    emit WithdrawPausedUpdated(msg.sender, withdrawPaused);
  }

  /**
   * @dev Sets the withdrawToChain pause state
   * @param paused Whether to pause withdrawToChain
   */
  function setWithdrawToChainPause(bool paused) external onlyRole(EDITOR_ROLE) {
    withdrawToChainPaused = paused;
    emit WithdrawToChainPausedUpdated(msg.sender, withdrawToChainPaused);
  }

  /**
   * @dev Sets the internal transfer pause state
   * @param paused Whether to pause internal transfers
   */
  function setInternalTransferPause(bool paused) external onlyRole(EDITOR_ROLE) {
    internalTransferPaused = paused;
    emit InternalTransferPausedUpdated(msg.sender, internalTransferPaused);
  }

  /**
   * @dev Sets the Zipper Endpoint contract address
   * @param _zipperEndpoint The address of the Zipper Endpoint contract
   */
  function setZipperEndpoint(address _zipperEndpoint) external onlyRole(EDITOR_ROLE) {
    if (_zipperEndpoint == address(0)) revert ZeroAddress();
    zipperEndpoint = IZipperEndpoint(_zipperEndpoint);
    emit ZipperEndpointSet(_zipperEndpoint);
  }

  /**
   * @dev Configures deposit and withdrawal permissions for a zToken
   * @param token The address of the token to configure
   * @param enabled Whether the token should be enabled
   * @param depositAllowed Whether deposits should be allowed for this token
   * @param withdrawAllowed Whether withdrawals should be allowed for this token
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   *
   * Emits a {ZTokenConfigSet} event
   */
  function configZToken(address token, bool enabled, bool depositAllowed, bool withdrawAllowed) external onlyRole(EDITOR_ROLE) {
    zTokenConfigs[token] = TokenConfig(enabled, depositAllowed, withdrawAllowed);

    emit ZTokenConfigSet(token, enabled, depositAllowed, withdrawAllowed);
  }

  /**
   * @dev Configures deposit and withdrawal permissions for a unified asset
   * @param uAssetName The name of the unified asset to configure
   * @param enabled Whether the unified asset should be enabled
   * @param depositAllowed Whether deposits should be allowed for this asset
   * @param withdrawAllowed Whether withdrawals should be allowed for this asset
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   *
   * Emits a {UAssetConfigSet} event
   */
  function configUAsset(string memory uAssetName, bool enabled, bool depositAllowed, bool withdrawAllowed) external onlyRole(EDITOR_ROLE) {
    bytes32 uAssetId = keccak256(abi.encodePacked(StringLib.toLowerCase(uAssetName)));
    uAssetConfigs[uAssetId] = TokenConfig(enabled, depositAllowed, withdrawAllowed);

    emit UAssetConfigSet(uAssetId, enabled, depositAllowed, withdrawAllowed);
  }

  /**
   * @dev Maps a zToken to a unified asset
   * @param zToken The address of the zToken to map
   * @param uAssetId The ID of the unified asset to map to
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   * - zToken must not be zero address
   * - uAsset must be enabled
   * - zToken must not already be mapped
   *
   * Emits a {ZTokenToUAssetSet} event
   */
  function mapZTokenToUAsset(address zToken, bytes32 uAssetId) external onlyRole(EDITOR_ROLE) {
    if (zToken == address(0)) revert ZeroAddress();
    if (uAssetId == bytes32(0)) revert ZeroId();
    if (!uAssetConfigs[uAssetId].enabled) revert UAssetDisabled();
    if (zTokenToUAsset[zToken] != bytes32(0)) revert ZTokenAlreadyMapped();
    if (poolZBalances[zToken] != 0) revert ZTokenOutstandingBalances();

    zTokenToUAsset[zToken] = uAssetId;

    emit ZTokenToUAssetSet(zToken, uAssetId);
  }

  /**
   * @dev Unmaps a zToken from its unified asset
   * @param zToken The address of the zToken to unmap
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   * - zToken must not be zero address
   * - zToken must be mapped to a unified asset
   *
   * Emits a {ZTokenToUAssetUnset} event
   */
  function unmapZTokenFromUAsset(address zToken) external onlyRole(EDITOR_ROLE) {
    if (zToken == address(0)) revert ZeroAddress();
    if (zTokenToUAsset[zToken] == bytes32(0)) revert ZTokenNotMapped();
    if (poolZBalances[zToken] != 0) revert ZTokenOutstandingBalances();

    zTokenToUAsset[zToken] = bytes32(0);

    emit ZTokenToUAssetUnset(zToken);
  }

  /**
   * @dev Sets the allowed status for a app
   * @param app The app contract address to add
   * @param allowed The allowed status to set
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   * - App address must be non-zero
   *
   * Note: After adding a app, use setAppAllowedUAssets() to register the uAssets this app can work with
   *
   * Emits an {AllowedAppSet} event
   */
  function setAllowedApp(address app, bool allowed) external onlyRole(EDITOR_ROLE) {
    if (app == address(0)) revert ZeroAddress();
    allowedApps[app] = allowed;

    emit AllowedAppSet(app, allowed);
  }

  /**
   * @dev Sets the allowed status for multiple uAssets for a specific app
   * @param app The app address
   * @param uAssetList Array of uAsset ids to set the allowed status for
   * @param allowed The allowed status to set
   *
   * Requirements:
   * - Caller must have EDITOR_ROLE
   * - App address must be non-zero
   *
   * Emits {AppAllowedUAssetsSet} events for each uAsset
   */
  function setAppAllowedUAssets(address app, bytes32[] calldata uAssetList, bool allowed) external onlyRole(EDITOR_ROLE) {
    if (app == address(0)) revert ZeroAddress();
    for (uint256 i = 0; i < uAssetList.length; i++) {
      if (uAssetList[i] == bytes32(0)) revert ZeroAddress();
      appAllowedUAssets[app][uAssetList[i]] = allowed;
      emit AppAllowedUAssetsSet(app, uAssetList[i], allowed);
    }
  }

  // ============ INTERNAL APP FUNCTIONS ============

  /**
   * @dev Freezes an account's available balance for trading operations and credits the frozen balance to another account (called by allowed apps)
   * Moves funds from `fromAccount` available balance to `toAccount` frozen balance pool
   * @param fromAccount The account whose balance should be frozen
   * @param toAccount The account who will receive the frozen balance
   * @param uAssetId The uAsset id to freeze
   * @param uAmount The amount to freeze
   *
   * Requirements:
   * - Caller must be an allowed app containing the specified uAssetId
   */
  function appFreeze(
    address fromAccount,
    address toAccount,
    bytes32 uAssetId,
    uint256 uAmount
  ) external onlyAllowedApp(uAssetId) whenInternalTransferNotPaused {
    accountUBalances[fromAccount][uAssetId] -= uAmount;
    appUBalances[msg.sender][toAccount][uAssetId] += uAmount;
  }

  /**
   * @dev Unfreezes an account's balance and transfers it to another account (called by allowed apps)
   * Moves funds from the app frozen balance pool to `toAccount` available balance
   * @param fromAccount The account whose frozen balance should be unfrozen
   * @param toAccount The account who should receive the unfrozen balance
   * @param uAssetId The uAsset id to unfreeze
   * @param uAmount The amount to unfreeze and transfer
   *
   * Requirements:
   * - Caller must be an allowed app containing the specified uAssetId
   */
  function appUnfreeze(
    address fromAccount,
    address toAccount,
    bytes32 uAssetId,
    uint256 uAmount
  ) external onlyAllowedApp(uAssetId) whenInternalTransferNotPaused {
    appUBalances[msg.sender][fromAccount][uAssetId] -= uAmount;
    accountUBalances[toAccount][uAssetId] += uAmount;
  }

  /**
   * @dev Withdraws zTokens directly to a destination chain via Zipper Bridge on behalf of an account.
   *      Called by allowed apps.
   * @notice The caller (app) must ensure the account has sufficient available balance.
   *         If the app previously froze account funds (in the app frozen pool), the app
   *         must first calculate and unlock (unfreeze) the necessary amount from its pool
   *         back to the account's available balance before calling this function.
   *         This function operates only on the account's available balance.
   * @param account The account address
   * @param request The withdrawal request structure containing all details
   */
  function appWithdrawToChain(
    address account,
    IZipperEndpoint.WithdrawRequest calldata request
  ) external override whenWithdrawToChainNotPaused returns (uint256 requestId) {
    bytes32 uAssetId = zTokenToUAsset[request.zToken];
    if (uAssetId == bytes32(0)) revert ZTokenNotMapped();
    if (!allowedApps[msg.sender] || !appAllowedUAssets[msg.sender][uAssetId]) revert Forbidden();

    return _withdrawToChain(account, request, WITHDRAW_ORIGIN_TRADING_GATEWAY, msg.sender);
  }

  // ============ INTERNAL FUNCTIONS ============

  function _validateExternalDestinationAllowlist(address account, uint16 chainId, bytes calldata withdrawDestination) internal view {
    if (!externalDestinationAllowlistRequired[account]) return;

    bytes[] memory allowlisted = allowedExternalDestinations[account][chainId];
    if (allowlisted.length == 0) revert NoAllowlistSet();

    bytes32 targetHash = keccak256(withdrawDestination);
    for (uint256 i = 0; i < allowlisted.length; i++) {
      if (keccak256(allowlisted[i]) == targetHash) {
        return;
      }
    }

    revert AllowlistMismatch();
  }

  function _setDelegate(address account, address delegate, bool enabled) internal {
    if (!enabled && !isDelegate[account][delegate]) revert NothingToRemove();

    isDelegate[account][delegate] = enabled;
    emit DelegateUpdated(account, delegate, enabled);
  }

  function _setExternalDestinationAllowlistRequired(address account, bool required) internal {
    externalDestinationAllowlistRequired[account] = required;
    emit ExternalDestinationAllowlistRequirementUpdated(account, required);
  }

  function _setInternalAccountAllowlistRequired(address account, bool required) internal {
    internalAccountAllowlistRequired[account] = required;
    emit InternalAccountAllowlistRequirementUpdated(account, required);
  }

  function _addAllowedExternalDestinations(address account, uint16 chainId, bytes[] calldata destinations) internal {
    if (destinations.length == 0) revert InvalidAllowlistEntry();

    bytes[] storage current = allowedExternalDestinations[account][chainId];
    for (uint256 i = 0; i < destinations.length; i++) {
      if (destinations[i].length == 0) revert InvalidAllowlistEntry();
      if (_containsBytes(current, destinations[i])) continue;
      if (current.length >= MAX_ALLOWED_EXTERNAL_DESTINATIONS) revert AllowlistTooLarge();
      current.push(destinations[i]);
    }

    emit AllowedExternalDestinationsUpdated(account, chainId, current);
  }

  function _removeAllowedExternalDestinations(address account, uint16 chainId, bytes[] calldata destinations) internal {
    if (destinations.length == 0) revert InvalidAllowlistEntry();

    bytes[] storage current = allowedExternalDestinations[account][chainId];
    if (current.length == 0) revert NoAllowlistSet();

    bool removedAny = false;
    for (uint256 i = 0; i < destinations.length; i++) {
      if (destinations[i].length == 0) revert InvalidAllowlistEntry();
      removedAny = _removeBytes(current, destinations[i]) || removedAny;
    }
    if (!removedAny) revert NothingToRemove();

    emit AllowedExternalDestinationsUpdated(account, chainId, current);
  }

  function _addAllowedInternalAccounts(address account, address[] calldata accounts) internal {
    if (accounts.length == 0) revert InvalidAllowlistEntry();

    address[] storage current = allowedInternalAccounts[account];
    for (uint256 i = 0; i < accounts.length; i++) {
      if (accounts[i] == address(0)) revert InvalidAllowlistEntry();
      if (_containsAddress(current, accounts[i])) continue;
      if (current.length >= MAX_ALLOWED_INTERNAL_ACCOUNTS) revert AllowlistTooLarge();
      current.push(accounts[i]);
    }

    emit AllowedInternalAccountsUpdated(account, current);
  }

  function _removeAllowedInternalAccounts(address account, address[] calldata accounts) internal {
    if (accounts.length == 0) revert InvalidAllowlistEntry();

    address[] storage current = allowedInternalAccounts[account];
    if (current.length == 0) revert NoAllowlistSet();

    bool removedAny = false;
    for (uint256 i = 0; i < accounts.length; i++) {
      if (accounts[i] == address(0)) revert InvalidAllowlistEntry();
      removedAny = _removeAddress(current, accounts[i]) || removedAny;
    }
    if (!removedAny) revert NothingToRemove();

    emit AllowedInternalAccountsUpdated(account, current);
  }

  function _consumeApproval(address account, bytes4 selector, bytes32 paramsHash, IGuardRegistry.Approval calldata approval) internal {
    IGuardRegistry registry = guardRegistry;
    if (address(registry) == address(0)) revert GuardRegistryNotSet();

    registry.consumeApproval(account, address(this), selector, paramsHash, approval);
  }

  function validateInternalAccountAllowlist(address fromAccount, address toAccount) external view override {
    _validateInternalAccountAllowlist(fromAccount, toAccount);
  }

  function _validateInternalAccountAllowlist(address fromAccount, address toAccount) internal view {
    if (!internalAccountAllowlistRequired[fromAccount]) return;

    address[] memory allowlisted = allowedInternalAccounts[fromAccount];
    if (allowlisted.length == 0) revert NoAllowlistSet();

    for (uint256 i = 0; i < allowlisted.length; i++) {
      if (allowlisted[i] == toAccount) {
        return;
      }
    }

    revert AllowlistMismatch();
  }

  function _containsBytes(bytes[] storage current, bytes calldata candidate) internal view returns (bool) {
    bytes32 candidateHash = keccak256(candidate);
    for (uint256 i = 0; i < current.length; i++) {
      if (keccak256(current[i]) == candidateHash) {
        return true;
      }
    }

    return false;
  }

  function _removeBytes(bytes[] storage current, bytes calldata candidate) internal returns (bool) {
    bytes32 candidateHash = keccak256(candidate);
    for (uint256 i = 0; i < current.length; i++) {
      if (keccak256(current[i]) == candidateHash) {
        uint256 lastIndex = current.length - 1;
        if (i != lastIndex) {
          current[i] = current[lastIndex];
        }
        current.pop();
        return true;
      }
    }

    return false;
  }

  function _containsAddress(address[] storage current, address candidate) internal view returns (bool) {
    for (uint256 i = 0; i < current.length; i++) {
      if (current[i] == candidate) {
        return true;
      }
    }

    return false;
  }

  function _removeAddress(address[] storage current, address candidate) internal returns (bool) {
    for (uint256 i = 0; i < current.length; i++) {
      if (current[i] == candidate) {
        uint256 lastIndex = current.length - 1;
        if (i != lastIndex) {
          current[i] = current[lastIndex];
        }
        current.pop();
        return true;
      }
    }

    return false;
  }

  function _resolveWithdrawAmounts(
    address zToken,
    uint256 zAmount
  ) internal view returns (bytes32 uAssetId, uint256 uAmount, uint256 normalizedZAmount) {
    if (zToken == address(0)) revert ZeroAddress();
    if (!zTokenConfigs[zToken].enabled) revert ZTokenDisabled();
    if (!zTokenConfigs[zToken].withdraw) revert ZWithdrawDisabled();

    uAssetId = zTokenToUAsset[zToken];
    if (uAssetId == bytes32(0)) revert ZTokenNotMapped();
    if (!uAssetConfigs[uAssetId].withdraw) revert UWithdrawDisabled();

    (uAmount, normalizedZAmount) = MathLib.convertDecimals(zAmount, IERC20Metadata(zToken).decimals(), U_DECIMALS);
    if (uAmount == 0) revert InvalidAmount();
  }

  function _deductPoolZBalance(address zToken, uint256 zAmount) internal {
    uint256 currentPoolZBalance = poolZBalances[zToken];
    if (currentPoolZBalance < zAmount) revert PoolZInsufficientBalance();
    poolZBalances[zToken] = currentPoolZBalance - zAmount;
  }

  function _deductUserAndPoolUBalance(address account, bytes32 uAssetId, uint256 uAmount) internal {
    uint256 currentUserBalance = accountUBalances[account][uAssetId];
    if (currentUserBalance < uAmount) revert UserUInsufficientBalance();
    accountUBalances[account][uAssetId] = currentUserBalance - uAmount;

    uint256 currentPoolUBalance = poolUBalances[uAssetId];
    if (currentPoolUBalance < uAmount) revert PoolUInsufficientBalance();
    poolUBalances[uAssetId] = currentPoolUBalance - uAmount;
  }

  /**
   * @dev Mints zTokens and updates the balances of the account
   * @param zToken The address of the zToken to mint
   * @param creditedAccount The account to credit
   * @param zAmount The amount of zTokens to mint
   * @return zAddedAmount The amount of zTokens added
   * @return uAssetId The ID of the unified asset to mint
   * @return uAmount The amount of the unified asset to mint
   */
  function _deposit(
    address zToken,
    address creditedAccount,
    uint256 zAmount,
    bool emitEvent
  ) internal returns (uint256 zAddedAmount, bytes32 uAssetId, uint256 uAmount) {
    if (zToken == address(0)) revert ZeroAddress();
    if (!zTokenConfigs[zToken].enabled) revert ZTokenDisabled();
    if (!zTokenConfigs[zToken].deposit) revert ZDepositDisabled();
    if (creditedAccount == address(0)) revert ZeroAddress();
    if (zAmount == 0) revert InvalidAmount();

    IERC20 tokenContract = IERC20(zToken);
    uint256 currentBalance_ = tokenContract.balanceOf(address(this));
    tokenContract.safeTransferFrom(msg.sender, address(this), zAmount);
    uint256 newBalance_ = tokenContract.balanceOf(address(this));
    zAddedAmount = newBalance_ - currentBalance_;

    poolZBalances[zToken] += zAddedAmount;

    uAssetId = zTokenToUAsset[zToken];
    if (uAssetId == bytes32(0)) revert ZTokenNotMapped();
    if (!uAssetConfigs[uAssetId].deposit) revert UAssetDisabled();

    (uAmount, ) = MathLib.convertDecimals(zAddedAmount, IERC20Metadata(zToken).decimals(), U_DECIMALS);
    if (uAmount == 0) revert InvalidAmount();
    accountUBalances[creditedAccount][uAssetId] += uAmount;
    poolUBalances[uAssetId] += uAmount;

    if (emitEvent) {
      emit Deposit(msg.sender, creditedAccount, zToken, zAddedAmount, uAssetId, uAmount);
    }
  }
}
