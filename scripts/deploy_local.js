// yarn deploy:local
//
// Deploys and links the bridge contracts, registers one EVM chain and creates the zToken of a test source token.
// Runs on the in-process Hardhat network only. Tests can call deployLocal() for a fresh deployment.
//
// Each proxy gets its own ProxyAdmin (OpenZeppelin 5.1.0); on testnet the proxies share one.
const hre = require('hardhat');
const proxyArtifact = require('@openzeppelin/contracts/build/contracts/TransparentUpgradeableProxy.json');

const { ethers } = hre;

const CHAIN_ID = 2;
const CHAIN_CONFIG = {
  chainName: 'Local EVM Chain',
  isCaseSensitive: false,
  minAddressLength: 42,
  maxAddressLength: 42,
  isEnabled: true,
};
// EVM chains share one address family, so a deposit address belongs to the same account on all of them.
const EVM_ADDRESS_FAMILY_ID = 1;
const STOKEN = { name: 'Local USD', symbol: 'lUSD', decimals: 6, supply: 1_000_000 };
const UASSET_NAME = 'uUSD';
const BASE_FEE = ethers.parseUnits('1', 18);
const MAX_BATCH_SIZE = 100;
const ZTOKEN_DEADLINE_SECONDS = 10 * 60;

const role = (name) => ethers.id(name);

// Addresses and transaction hashes of other chains are stored on-chain as UTF-8 text bytes.
const encodeText = (text) => ethers.hexlify(ethers.toUtf8Bytes(text.toLowerCase()));

const assertHardhatNetwork = () => {
  if (hre.network.name !== 'hardhat') {
    throw new Error(`These scripts run on the in-process Hardhat network only, not on "${hre.network.name}"`);
  }
};

const send = async (transaction) => (await transaction).wait();

const getAccounts = async () => {
  const [deployer, relayer, executor, feeRecipient, user, depositWallet, vault, sender, destination, ...rest] =
    await ethers.getSigners();
  return {
    deployer,
    relayer,
    executor,
    feeRecipient,
    user,
    depositWallet,
    vault,
    sender,
    destination,
    validators: rest.slice(0, 4),
    retirer: rest[4],
  };
};

const deployProxy = async (deployer, name, args = []) => {
  const implementation = await ethers.deployContract(name);
  await implementation.waitForDeployment();
  const initData = implementation.interface.encodeFunctionData(`${name}Init`, args);
  const proxyFactory = new ethers.ContractFactory(proxyArtifact.abi, proxyArtifact.bytecode, deployer);
  const proxy = await proxyFactory.deploy(implementation.target, deployer.address, initData);
  await proxy.waitForDeployment();
  return ethers.getContractAt(name, proxy.target);
};

const deployContracts = async ({ deployer }) => {
  const factoryChain = await deployProxy(deployer, 'ZipperFactoryChain');
  const factoryToken = await deployProxy(deployer, 'ZipperFactoryToken', [factoryChain.target]);
  const factoryKey = await deployProxy(deployer, 'ZipperFactoryKey', [factoryChain.target]);
  const factoryFee = await deployProxy(deployer, 'ZipperFactoryFee', [factoryChain.target]);
  const factoryVault = await deployProxy(deployer, 'ZipperFactoryVault', [factoryChain.target]);
  const factorySubVault = await deployProxy(deployer, 'ZipperFactorySubVault', [factoryChain.target]);
  const endpoint = await deployProxy(deployer, 'ZipperEndpoint', [
    factoryChain.target,
    factoryToken.target,
    factoryKey.target,
    factoryFee.target,
  ]);
  const depositBatchRouter = await deployProxy(deployer, 'DepositBatchRouter', [endpoint.target, MAX_BATCH_SIZE]);
  const fundingAccount = await deployProxy(deployer, 'FundingAccount');
  const guardRegistry = await ethers.deployContract('GuardRegistry');
  await guardRegistry.waitForDeployment();

  return {
    factoryChain,
    factoryToken,
    factoryKey,
    factoryFee,
    factoryVault,
    factorySubVault,
    endpoint,
    depositBatchRouter,
    fundingAccount,
    guardRegistry,
  };
};

const linkContracts = async ({ deployer, relayer, executor, feeRecipient, validators, retirer }, contracts) => {
  const { factoryToken, factoryKey, factoryFee, factoryVault, factorySubVault, endpoint } = contracts;
  const { depositBatchRouter, fundingAccount, guardRegistry } = contracts;

  await send(factoryToken.grantRole(role('CREATE_TOKEN_ROLE'), deployer.address));
  await send(factoryToken.grantRole(role('MINT_TOKEN_ROLE'), endpoint.target));
  await send(factoryToken.grantRole(role('BURN_TOKEN_ROLE'), endpoint.target));
  await send(factoryKey.grantRole(role('CREATE_KEY_ROLE'), deployer.address));
  await send(factoryKey.grantRole(role('CHANGE_KEY_ROLE'), deployer.address));
  await send(factoryKey.grantRole(role('RETIRE_KEY_ROLE'), retirer.address));
  await send(factoryVault.grantRole(role('CREATE_VAULT_ROLE'), deployer.address));
  await send(factoryVault.grantRole(role('CHANGE_VAULT_ROLE'), deployer.address));
  await send(factorySubVault.grantRole(role('ADD_SUB_VAULT_ROLE'), deployer.address));
  await send(factoryFee.setEndpoint(endpoint.target, true));
  await send(factoryFee.setDefaultFeeRecipient(feeRecipient.address));

  await send(endpoint.setVaultFactories(factoryVault.target, factorySubVault.target));
  await send(endpoint.grantRole(role('RELAYER_ROLE'), depositBatchRouter.target));
  await send(endpoint.grantRole(role('EXECUTOR_ROLE'), executor.address));
  await send(endpoint.grantRole(role('REFUND_DEPOSIT_ROLE'), executor.address));
  await send(endpoint.grantRole(role('REFUND_WITHDRAW_ROLE'), executor.address));
  await send(endpoint.grantRole(role('VALIDATOR_MANAGER_ROLE'), deployer.address));
  const validatorAddresses = validators.map(({ address }) => address);
  await send(endpoint.setValidator(validatorAddresses, true));
  await send(endpoint.setValidationQuorumThreshold(validatorAddresses.length));
  await send(depositBatchRouter.setRelayer(relayer.address, true));

  // Approved deposits are credited to FundingAccount, and FundingAccount can create withdrawal requests.
  await send(factoryToken.setAllowedRouteReceiver(fundingAccount.target, true));
  await send(factoryToken.setEndpointRouteReceiver(endpoint.target, fundingAccount.target));
  await send(fundingAccount.grantRole(role('MINTER_ROLE'), factoryToken.target));
  await send(fundingAccount.setZipperEndpoint(endpoint.target));
  await send(endpoint.grantRole(role('WHITELISTED_AGENT_ROLE'), fundingAccount.target));
  await send(fundingAccount.setGuardRegistry(guardRegistry.target));
  await send(guardRegistry.grantRole(role('AUTHORIZED_CALLER_ROLE'), fundingAccount.target));
};

const registerChain = async ({ factoryChain }) => {
  await send(factoryChain.upsertChain(CHAIN_ID, CHAIN_CONFIG));
  await send(factoryChain.setAddressFamily(CHAIN_ID, EVM_ADDRESS_FAMILY_ID));
};

// Stands in for a token on the source chain. It is not part of the bridge.
const deploySToken = async () => {
  const { name, symbol, decimals, supply } = STOKEN;
  const sToken = await ethers.deployContract('SToken', [name, symbol, decimals, supply]);
  await sToken.waitForDeployment();
  return sToken;
};

const createZToken = async ({ deployer }, { factoryToken }, sToken) => {
  const { chainId } = await ethers.provider.getNetwork();
  const { timestamp } = await ethers.provider.getBlock('latest');
  const value = {
    requester: deployer.address,
    chainId: CHAIN_ID,
    rawToken: sToken.target,
    name: STOKEN.name,
    symbol: `z${STOKEN.symbol}`,
    description: '',
    deadline: timestamp + ZTOKEN_DEADLINE_SECONDS,
  };
  const domain = { name: 'ZipperFactoryToken', version: '1.0.0', chainId, verifyingContract: factoryToken.target };
  const types = {
    ZipperFactoryToken: [
      { name: 'requester', type: 'address' },
      { name: 'chainId', type: 'uint16' },
      { name: 'rawToken', type: 'string' },
      { name: 'name', type: 'string' },
      { name: 'symbol', type: 'string' },
      { name: 'description', type: 'string' },
      { name: 'deadline', type: 'uint256' },
    ],
  };
  const signature = await deployer.signTypedData(domain, types, value);
  const { rawToken, name, symbol, description, deadline } = value;
  await send(factoryToken.createZToken(CHAIN_ID, rawToken, name, symbol, description, deadline, signature));
  return ethers.getContractAt('ZToken', await factoryToken.srcToZToken(CHAIN_ID, encodeText(sToken.target)));
};

const configureZToken = async ({ vault }, { factoryFee, factoryVault, fundingAccount }, sToken, zToken) => {
  await send(factoryFee.setBaseFeesBatch([CHAIN_ID], [zToken.target], [BASE_FEE]));
  await send(factoryVault.createVault(CHAIN_ID, encodeText(sToken.target), encodeText(vault.address)));

  const [uAssetId] = await fundingAccount.genUAssetId(UASSET_NAME);
  await send(fundingAccount.configUAsset(UASSET_NAME, true, true, true));
  await send(fundingAccount.configZToken(zToken.target, true, true, true));
  await send(fundingAccount.mapZTokenToUAsset(zToken.target, uAssetId));
  return uAssetId;
};

const deployLocal = async () => {
  assertHardhatNetwork();

  const accounts = await getAccounts();
  const contracts = await deployContracts(accounts);
  await linkContracts(accounts, contracts);
  await registerChain(contracts);
  const sToken = await deploySToken();
  const zToken = await createZToken(accounts, contracts, sToken);
  const uAssetId = await configureZToken(accounts, contracts, sToken, zToken);

  return { accounts, contracts, sToken, zToken, uAssetId, chainId: CHAIN_ID, baseFee: BASE_FEE };
};

const main = async () => {
  const { contracts, sToken, zToken, uAssetId, chainId } = await deployLocal();
  console.log(`Chain ${chainId} registered: ${CHAIN_CONFIG.chainName}`);
  for (const [name, { target }] of Object.entries({ ...contracts, sToken, zToken })) console.log(name.padEnd(20), target);
  console.log('uAssetId'.padEnd(20), uAssetId);
};

module.exports = { deployLocal, encodeText, send };

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
