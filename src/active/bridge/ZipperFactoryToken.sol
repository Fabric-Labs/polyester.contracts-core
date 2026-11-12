// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IProgramReceiver.sol";
import "../tokens/ZToken.sol";
import "./ZipperFactoryChain.sol";

contract ZipperFactoryToken is EIP712Upgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for ZToken;

  bytes32 internal constant CREATE_TOKEN_ROLE = keccak256("CREATE_TOKEN_ROLE");
  bytes32 internal constant MINT_TOKEN_ROLE = keccak256("MINT_TOKEN_ROLE");
  bytes32 internal constant BURN_TOKEN_ROLE = keccak256("BURN_TOKEN_ROLE");
  bytes32 internal constant TOKEN_OWNERSHIP_ROLE = keccak256("TOKEN_OWNERSHIP_ROLE");
  bytes32 internal constant EDIT_ROUTE_RECEIVER_ROLE = keccak256("EDIT_ROUTE_RECEIVER_ROLE");
  bytes32 internal constant TOKEN_STATUS_ROLE = keccak256("TOKEN_STATUS_ROLE");

  uint8 internal constant ZTOKEN_DEPOSIT_DISABLED = 1;
  uint8 internal constant ZTOKEN_WITHDRAWAL_DISABLED = 2;
  uint8 internal constant ZTOKEN_ALL_DISABLED = 3;

  ZipperFactoryChain public chain;

  // srcToZToken[chainId][srcToken] = zToken
  mapping(uint16 => mapping(bytes => address)) public srcToZToken;
  // zTokenToSrc[chainId][zToken] = srcToken
  mapping(uint16 => mapping(address => bytes)) public zTokenToSrc;

  // allowedRouteReceivers[routeReceiver] = allowed
  mapping(address => bool) public allowedRouteReceivers;
  // endpointRouteReceiver[endpoint] = route receiver address (0x0 = default to account)
  mapping(address => address) public endpointRouteReceiver;
  // zTokenPauseFlags[chainId][zToken] = operation-specific pause flags
  mapping(uint16 => mapping(address => uint8)) public zTokenPauseFlags;

  event ZTokenCreated(uint16 indexed chainId, bytes indexed srcToken, address indexed zToken);
  event ZTokenMinted(uint256 indexed requestId, uint16 indexed chainId, address indexed zToken, address tokenRecipient, uint256 zAmount);
  event ZTokenBurned(uint256 indexed requestId, uint16 indexed chainId, address indexed zToken, address fromAccount, uint256 zAmount);
  event ZipperRouteStarted(uint256 indexed requestId, address indexed account, address indexed zToken, uint256 zAmount, address routeReceiver);
  event ZipperRouteCompleted(
    uint256 indexed requestId,
    address indexed account,
    address indexed zToken,
    uint256 zAmount,
    address routeReceiver,
    bool creditedToReceiver,
    address finalRouteReceiver
  );
  event ZTokenDescriptionUpdated(address indexed zToken, string description);
  event EndpointRouteReceiverSet(address indexed endpoint, address indexed routeReceiver);
  event RouteReceiverAllowedStatusChanged(address indexed routeReceiver, bool allowed);
  event ZTokenPauseFlagsUpdated(uint16 indexed chainId, address indexed zToken, uint8 pauseFlags);

  error ExpiredDeadline();
  error InvalidDeadline();
  error InvalidRole();
  error ZTokenAlreadyExists();
  error InvalidZTokenAddress();
  error InvalidTokenRecipient();
  error InvalidFromAccount();
  error InvalidAccount();
  error InvalidAmount();
  error SourceTokenNotFound();
  error FactoryNotTokenOwner();
  error InvalidRouteReceiver();
  error InvalidSenderAddress();
  error RouteReceiverRejected();
  error InvalidZTokenPauseFlags();
  error ZTokenPauseFlagsUnchanged();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function ZipperFactoryTokenInit(ZipperFactoryChain _chain) external initializer {
    __EIP712_init("ZipperFactoryToken", "1.0.0");
    __AccessControl_init();
    __ReentrancyGuard_init();

    address sender_ = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, sender_);
    _grantRole(EDIT_ROUTE_RECEIVER_ROLE, sender_);
    _grantRole(TOKEN_STATUS_ROLE, sender_);

    chain = _chain;
  }

  /**
   * @notice Creates a new ZToken for a given source token.
   */
  function createZToken(
    uint16 chainId,
    string memory rawToken,
    string memory name,
    string memory symbol,
    string memory description,
    uint256 deadline,
    bytes calldata signature
  ) external nonReentrant {
    // Check deadline should be in a valid window 15 minutes
    if (block.timestamp > deadline) revert ExpiredDeadline();
    if (deadline > block.timestamp + 15 minutes) revert InvalidDeadline();
    // Validate the signature
    if (!hasRole(CREATE_TOKEN_ROLE, _validateSignature(chainId, rawToken, name, symbol, description, deadline, signature))) revert InvalidRole();

    // Encode the source token address
    bytes memory srcToken = chain.encodeAddress(chainId, rawToken);

    if (srcToZToken[chainId][srcToken] != address(0)) revert ZTokenAlreadyExists();

    // Deploy a new ZToken
    ZToken zToken = new ZToken(name, symbol, description);
    srcToZToken[chainId][srcToken] = address(zToken);
    zTokenToSrc[chainId][address(zToken)] = srcToken;

    emit ZTokenCreated(chainId, srcToken, address(zToken));
  }

  /**
   * @notice Mints ZToken for a Zipper request and emits request-aware route markers.
   * @dev Use this for endpoint deposits that may credit a route receiver and need off-chain correlation.
   */
  function mintZTokenForRequest(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address account,
    uint256 zAmount
  ) external nonReentrant onlyRole(MINT_TOKEN_ROLE) {
    _validateMintParams(chainId, zToken, account, zAmount);

    address routeReceiver = _routeReceiverFor(_msgSender());
    emit ZipperRouteStarted(requestId, account, zToken, zAmount, routeReceiver);
    (bool creditedToReceiver, address finalRouteReceiver) = _mintZTokenWithRouting(requestId, chainId, zToken, account, zAmount, routeReceiver);
    emit ZipperRouteCompleted(requestId, account, zToken, zAmount, routeReceiver, creditedToReceiver, finalRouteReceiver);
  }

  /**
   * @notice Mints ZToken to an address without endpoint route receiver routing (e.g. bridge fees).
   * @dev Same access as request-aware minting; use mintZTokenForRequest for account deposits that may credit a route receiver.
   */
  function mintZTokenDirect(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address tokenRecipient,
    uint256 zAmount
  ) external nonReentrant onlyRole(MINT_TOKEN_ROLE) {
    if (zToken == address(0)) revert InvalidZTokenAddress();
    if (tokenRecipient == address(0)) revert InvalidTokenRecipient();
    if (zAmount == 0) revert InvalidAmount();

    bytes memory srcToken = zTokenToSrc[chainId][zToken];
    if (srcToken.length == 0) revert SourceTokenNotFound();

    _mintZToken(requestId, chainId, zToken, tokenRecipient, zAmount, false);
  }

  /**
   * @notice Handles a request to burn ZToken based on the source chain token address.
   */
  function burnZTokenForRequest(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address fromAccount,
    uint256 zAmount
  ) external nonReentrant onlyRole(BURN_TOKEN_ROLE) {
    if (zToken == address(0)) revert InvalidZTokenAddress();
    if (fromAccount == address(0)) revert InvalidFromAccount();
    if (zAmount == 0) revert InvalidAmount();

    // Check if a source token already exists for the ZToken
    bytes memory srcToken = zTokenToSrc[chainId][zToken];
    if (srcToken.length == 0) revert SourceTokenNotFound();

    // Burn the specified amount of ZToken from the source account
    ZToken(zToken).safeTransferFrom(fromAccount, address(this), zAmount);
    ZToken(zToken).burn(zAmount);

    emit ZTokenBurned(requestId, chainId, zToken, fromAccount, zAmount);
  }

  // Transfer ownership of the ZToken contract
  function transferOwnership(address zToken, address newOwner) external onlyRole(TOKEN_OWNERSHIP_ROLE) {
    ZToken(zToken).transferOwnership(newOwner);
  }

  function updateZTokenDescription(address zToken, string calldata description) external onlyRole(TOKEN_OWNERSHIP_ROLE) {
    if (zToken == address(0)) revert InvalidZTokenAddress();
    if (ZToken(zToken).owner() != address(this)) revert FactoryNotTokenOwner();
    ZToken(zToken).updateDescription(description);
    emit ZTokenDescriptionUpdated(zToken, description);
  }

  function setZTokenPauseFlags(uint16 chainId, address zToken, uint8 pauseFlags) external onlyRole(TOKEN_STATUS_ROLE) {
    if (zTokenToSrc[chainId][zToken].length == 0) revert SourceTokenNotFound();
    if (pauseFlags > ZTOKEN_ALL_DISABLED) revert InvalidZTokenPauseFlags();
    if (zTokenPauseFlags[chainId][zToken] == pauseFlags) revert ZTokenPauseFlagsUnchanged();

    zTokenPauseFlags[chainId][zToken] = pauseFlags;
    emit ZTokenPauseFlagsUpdated(chainId, zToken, pauseFlags);
  }

  function getZTokenConfig(uint16 chainId, address zToken) external view returns (bytes memory srcToken, uint8 pauseFlags) {
    srcToken = zTokenToSrc[chainId][zToken];
    pauseFlags = zTokenPauseFlags[chainId][zToken];
  }

  /**
   * @notice Adds or removes a route receiver from the allowed list for mint-and-call functionality
   * @param routeReceiver The route receiver address to manage
   * @param allowed Whether the route receiver should be allowed
   */
  function setAllowedRouteReceiver(address routeReceiver, bool allowed) external onlyRole(EDIT_ROUTE_RECEIVER_ROLE) {
    if (routeReceiver == address(0)) revert InvalidRouteReceiver();
    allowedRouteReceivers[routeReceiver] = allowed;
    emit RouteReceiverAllowedStatusChanged(routeReceiver, allowed);
  }

  /**
   * @notice Sets the route receiver to mint to for force minting
   * @param endpoint The endpoint address to set the route receiver for
   * @param routeReceiver The route receiver address to mint to (address(0) for default to account)
   */
  function setEndpointRouteReceiver(address endpoint, address routeReceiver) external onlyRole(EDIT_ROUTE_RECEIVER_ROLE) {
    endpointRouteReceiver[endpoint] = routeReceiver;
    emit EndpointRouteReceiverSet(endpoint, routeReceiver);
  }

  function _validateMintParams(uint16 chainId, address zToken, address account, uint256 zAmount) internal view {
    if (zToken == address(0)) revert InvalidZTokenAddress();
    if (account == address(0)) revert InvalidAccount();
    if (zAmount == 0) revert InvalidAmount();

    bytes memory srcToken = zTokenToSrc[chainId][zToken];
    if (srcToken.length == 0) revert SourceTokenNotFound();
  }

  function _routeReceiverFor(address minter) internal view returns (address) {
    address routeReceiver = endpointRouteReceiver[minter];
    if (routeReceiver == address(0) || !allowedRouteReceivers[routeReceiver]) {
      return address(0);
    }
    return routeReceiver;
  }

  function _mintZTokenWithRouting(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address account,
    uint256 zAmount,
    address routeReceiver
  ) internal returns (bool creditedToReceiver, address finalRouteReceiver) {
    if (routeReceiver == address(0)) {
      _mintZToken(requestId, chainId, zToken, account, zAmount, true);
      return (false, account);
    }

    try this._tryMintToRouteReceiver(requestId, chainId, zToken, routeReceiver, account, zAmount) returns (address returnedFinalRouteReceiver) {
      return (true, returnedFinalRouteReceiver);
    } catch {
      _mintZToken(requestId, chainId, zToken, account, zAmount, true);
      return (false, account);
    }
  }

  /**
   * @notice Internal function to attempt minting to a route receiver with callback
   * @dev This function is external to enable try-catch but should only be called by this contract
   */
  function _tryMintToRouteReceiver(
    uint256 requestId,
    uint16 chainId,
    address zToken,
    address routeReceiver,
    address creditedAccount,
    uint256 zAmount
  ) external returns (address finalRouteReceiver) {
    if (msg.sender != address(this)) revert InvalidSenderAddress();

    _mintZToken(requestId, chainId, zToken, address(this), zAmount, false);

    // Approve the route receiver to pull the tokens
    ZToken(zToken).forceApprove(routeReceiver, zAmount);

    // Call onTokensMinted function on the route receiver
    bool accepted;
    (accepted, finalRouteReceiver) = IProgramReceiver(routeReceiver).onTokensMinted(requestId, chainId, zToken, creditedAccount, zAmount);
    if (!accepted) revert RouteReceiverRejected();
    if (finalRouteReceiver == address(0)) {
      return routeReceiver;
    }
  }

  /**
   * @notice Internal function to mint zToken and optionally emit the request-aware lifecycle event.
   */
  function _mintZToken(uint256 requestId, uint16 chainId, address zToken, address tokenRecipient, uint256 zAmount, bool emitEvent) internal {
    ZToken(zToken).mint(tokenRecipient, zAmount);
    if (emitEvent) {
      emit ZTokenMinted(requestId, chainId, zToken, tokenRecipient, zAmount);
    }
  }

  // Validate the signature to create a ZToken
  function _validateSignature(
    uint16 chainId,
    string memory rawToken,
    string memory name,
    string memory symbol,
    string memory description,
    uint256 deadline,
    bytes calldata signature
  ) internal view returns (address) {
    bytes32 digest_ = _hashTypedDataV4(
      keccak256(
        abi.encode(
          keccak256(
            "ZipperFactoryToken(address requester,uint16 chainId,string rawToken,string name,string symbol,string description,uint256 deadline)"
          ),
          _msgSender(),
          chainId,
          keccak256(bytes(rawToken)),
          keccak256(bytes(name)),
          keccak256(bytes(symbol)),
          keccak256(bytes(description)),
          deadline
        )
      )
    );
    return ECDSA.recover(digest_, signature);
  }
}
