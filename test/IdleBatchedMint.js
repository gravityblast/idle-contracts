const { expectEvent, singletons, constants, BN, expectRevert } = require('@openzeppelin/test-helpers');

const IdleTokenV3_1Mock = artifacts.require('IdleTokenV3_1Mock');
const IdleBatchedMint = artifacts.require('IdleBatchedMint');
const idleNewBatchMock = artifacts.require('IdleNewBatchMock');
const idleBatchMock = artifacts.require('IdleBatchMock');
const DAIMock = artifacts.require('DAIMock');
const cDAIMock = artifacts.require('cDAIMock');
const IdleRebalancerV3_1 = artifacts.require('IdleRebalancerV3_1');
const WhitePaperMock = artifacts.require('WhitePaperMock');
const cDAIWrapperMock = artifacts.require('cDAIWrapperMock');
const COMPMock = artifacts.require('COMPMock');

const BNify = n => new BN(String(n));

contract('IdleBatchedMint', function ([_, owner, manager, user1, user2, user3, user4]) {
  beforeEach(async () => {
    this.one = new BN('1000000000000000000');

    this.DAIMock = await DAIMock.new({ from: owner });
    this.WhitePaperMock = await WhitePaperMock.new({ from: owner });
    this.cDAIMock = await cDAIMock.new(this.DAIMock.address, owner, this.WhitePaperMock.address, {from: owner});

    this.protocolTokens = [
      this.cDAIMock.address,
    ];

    this.IdleRebalancer = await IdleRebalancerV3_1.new(
      this.protocolTokens,
      manager,
      { from: owner }
    );

    this.COMPMock = await COMPMock.new({ from: owner });
    this.IDLEMock = await COMPMock.new({ from: owner });

    this.token = await IdleTokenV3_1Mock.new(
      'IdleDAI',
      'IDLEDAI',
      this.DAIMock.address,
      this.DAIMock.address,
      this.DAIMock.address,
      this.IdleRebalancer.address,
      this.IDLEMock.address,
      this.COMPMock.address,
      { from: owner }
    );

    this.batchedMint = await IdleBatchedMint.new({ from: owner });
    await this.batchedMint.initialize(this.token.address, { from: owner });
  });

  it("creates batches", async () => {
    const deposit = async (user, amount) => {
      await this.DAIMock.transfer(user, amount, { from: owner });
      await this.DAIMock.approve(this.batchedMint.address, amount, { from: user });
      await this.batchedMint.deposit(amount, { from: user });
    }

    const checkBalance = async (who, token, amount) => {
      (await token.balanceOf(who)).toString().should.be.equal(amount);
    }

    const checkUserDeposit = async (user, batch, amount) => {
      (await this.batchedMint.batchDeposits(user, batch)).toString().should.be.equal(amount);
    }

    const checkBatchTotal = async (batch, amount) => {
      const batchBalance = await this.batchedMint.batchTotals(batch);
      batchBalance.toString().should.be.equal(amount);
    }

    const withdraw = async (user, batch, expectedAmount) => {
      const initialBalance = await this.token.balanceOf(user);
      await this.batchedMint.withdraw(0, { from: user1 });
      const balanceAfter = await this.token.balanceOf(user);
      balanceAfter.toString().should.be.equal(initialBalance.add(BNify(expectedAmount)).toString());
    }

    await checkBalance(this.batchedMint.address, this.token, "0");
    await checkBalance(this.batchedMint.address, this.DAIMock, "0");

    // 3 users depsit
    await deposit(user1, 10);
    await deposit(user2, 5);
    await deposit(user3, 6);

    // check deposit for each user
    await checkUserDeposit(user1, 0, "10");
    await checkUserDeposit(user2, 0, "5");
    await checkUserDeposit(user3, 0, "6");

    // check total deposit and contract tokens balance
    await checkBatchTotal(0, "21");
    await checkBalance(this.batchedMint.address, this.token, "0");
    await checkBalance(this.batchedMint.address, this.DAIMock, "21");

    // execute batch
    await this.batchedMint.executeBatch(true);

    // check contract tokens balance
    await checkBalance(this.batchedMint.address, this.token, "21");
    await checkBalance(this.batchedMint.address, this.DAIMock, "0");
    await checkBalance(user1, this.token, "0");

    // withdraw
    await withdraw(user1, 0, "10");

    // check user balance and contract balance
    await checkBalance(user1, this.token, "10");
    await checkBalance(this.batchedMint.address, this.token, "11");
  });
});
