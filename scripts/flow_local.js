// yarn flow:local
//
// Runs one deposit and one withdrawal on the deployment of deploy_local.js, on the in-process Hardhat network only.
// SToken transfers on the same network play the source and destination chain. The relayer, validator and executor
// steps are done directly by test accounts, without the off-chain checks.
const assert = require('node:assert/strict');
const { ethers } = require('hardhat');
const { deployLocal, encodeText, send } = require('./deploy_local');

const VALIDATION_APPROVED = 1n;
const EXECUTION_DISTRIBUTED = 2n;
const NO_REASON = 0;

const DEPOSIT_AMOUNT = '100';
const WITHDRAW_AMOUNT = '50';

const toZAmount = (amount) => ethers.parseUnits(amount, 18);

// Two thirds of the quorum threshold (4) approve a request, so three votes are enough.
const approve = async ({ endpoint }, validators, requestId) => {
  for (const validator of validators.slice(0, 3)) {
    await send(endpoint.connect(validator).validateRequest(requestId, true, NO_REASON));
  }
  assert.equal((await endpoint.validationStatuses(requestId)).status, VALIDATION_APPROVED);
};

const assertDistributed = async ({ endpoint }, requestId) =>
  assert.equal((await endpoint.executionStatuses(requestId)).status, EXECUTION_DISTRIBUTED);

const runDeposit = async ({ accounts, contracts, sToken, zToken, uAssetId, chainId, baseFee }) => {
  const { relayer, executor, feeRecipient, user, depositWallet, vault, sender, validators } = accounts;
  const { factoryKey, depositBatchRouter, endpoint, fundingAccount } = contracts;
  const sAmount = ethers.parseUnits(DEPOSIT_AMOUNT, await sToken.decimals());
  const zAmount = toZAmount(DEPOSIT_AMOUNT);

  // The user's deposit address on the source chain
  await send(factoryKey.createDepositAddress(chainId, user.address, encodeText(depositWallet.address)));

  // Source chain: the deposit
  await send(sToken.transfer(sender.address, sAmount));
  const { hash } = await send(sToken.connect(sender).transfer(depositWallet.address, sAmount));

  // The relayer submits the request with the amount converted to 18 decimals
  const requestId = await endpoint.totalRequests();
  const request = {
    chainId,
    zToken: zToken.target,
    sourceAddress: encodeText(sender.address),
    depositAddress: encodeText(depositWallet.address),
    zAmount,
    sourceHashTx: encodeText(hash),
    sourceHashIndex: 0,
  };
  await send(depositBatchRouter.connect(relayer).reqDepositZTokens([request], true));
  await approve(contracts, validators, requestId);
  await send(endpoint.connect(executor).executeRequests([requestId], true));
  await assertDistributed(contracts, requestId);

  assert.equal(await fundingAccount.accountUBalances(user.address, uAssetId), zAmount - baseFee);
  assert.equal(await zToken.balanceOf(fundingAccount.target), zAmount - baseFee);
  assert.equal(await zToken.balanceOf(feeRecipient.address), baseFee);
  assert.equal(await zToken.totalSupply(), zAmount);

  // Source chain: the sweep to the vault
  await send(sToken.connect(depositWallet).transfer(vault.address, sAmount));

  console.log(
    `Deposit request ${requestId}: ${DEPOSIT_AMOUNT} deposited, ${ethers.formatUnits(zAmount - baseFee)} credited as uAsset`,
  );
};

const runWithdrawal = async ({ accounts, contracts, sToken, zToken, uAssetId, chainId, baseFee }) => {
  const { executor, feeRecipient, user, vault, destination, validators } = accounts;
  const { endpoint, factoryFee, fundingAccount } = contracts;
  const zAmount = toZAmount(WITHDRAW_AMOUNT);
  const netZAmount = zAmount - baseFee;
  const uBalanceBefore = await fundingAccount.accountUBalances(user.address, uAssetId);
  const supplyBefore = await zToken.totalSupply();
  const feeBalanceBefore = await zToken.balanceOf(feeRecipient.address);

  const requestId = await endpoint.totalRequests();
  const request = {
    chainId,
    zToken: zToken.target,
    withdrawDestination: encodeText(destination.address),
    zAmount,
    maxFee: baseFee,
  };
  await send(fundingAccount.connect(user).withdrawToChain(request));
  assert.equal(await fundingAccount.accountUBalances(user.address, uAssetId), uBalanceBefore - zAmount);
  assert.equal(await zToken.balanceOf(endpoint.target), netZAmount);
  assert.equal(await zToken.balanceOf(factoryFee.target), baseFee);

  await approve(contracts, validators, requestId);
  await send(endpoint.connect(executor).executeRequests([requestId], true));

  // Destination chain: the payout, converted back to the token's decimals
  const sAmount = netZAmount / 10n ** (18n - (await sToken.decimals()));
  const { hash } = await send(sToken.connect(vault).transfer(destination.address, sAmount));

  // The executor commits the payout hash, then completes the request, which burns the locked zTokens
  await send(endpoint.connect(executor).commitWithdrawTxHash(requestId, encodeText(hash)));
  await send(endpoint.connect(executor).fulfillWithdrawRequest(requestId, encodeText(hash)));
  await assertDistributed(contracts, requestId);

  assert.equal(await zToken.balanceOf(endpoint.target), 0n);
  assert.equal(await zToken.balanceOf(factoryFee.target), 0n);
  assert.equal(await zToken.balanceOf(feeRecipient.address), feeBalanceBefore + baseFee);
  assert.equal(await zToken.totalSupply(), supplyBefore - netZAmount);
  assert.equal(await sToken.balanceOf(destination.address), sAmount);

  console.log(
    `Withdrawal request ${requestId}: ${WITHDRAW_AMOUNT} withdrawn, ${ethers.formatUnits(netZAmount)} paid out and burned`,
  );
};

const assertBacked = async ({ accounts, sToken, zToken }) => {
  const supply = await zToken.totalSupply();
  const backing = (await sToken.balanceOf(accounts.vault.address)) * 10n ** (18n - (await sToken.decimals()));
  assert.equal(supply, backing);
  console.log(`zToken supply ${ethers.formatUnits(supply)} equals the vault balance`);
};

const main = async () => {
  const deployment = await deployLocal();
  await runDeposit(deployment);
  await runWithdrawal(deployment);
  await assertBacked(deployment);
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
