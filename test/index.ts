/* eslint-disable no-unused-vars */
/* eslint-disable node/no-missing-import */
import { expect } from "chai";
import { ethers } from "hardhat";

import { BigNumber, ContractTransaction } from "ethers";

import { Staking, FarmCoin } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Staking", function () {
  enum DepositTokenType {
    Immediate = 0,
    ShortTerm = 1,
    LongTerm = 2,
  }
  const USDCAddr = "0xFE724a829fdF12F7012365dB98730EEe33742ea2";
  const AMOUNT_TO_STAKE = ethers.utils.parseUnits("100", 18);
  let owner: SignerWithAddress;
  let accounts: SignerWithAddress[];
  let staking: Staking;
  let farmCoin: FarmCoin;

  before("Before deploying", async function () {
    [owner, ...accounts] = await ethers.getSigners();
    farmCoin = await (await ethers.getContractFactory("FarmCoin")).deploy();
    await farmCoin.deployed();

    staking = await (
      await ethers.getContractFactory("Staking")
    ).deploy(USDCAddr, farmCoin.address);
    await staking.deployed();

    await farmCoin.connect(owner).mint(staking.address, AMOUNT_TO_STAKE);

    console.log(`FarmCoin deployed at: ${farmCoin.address}`);
  });

  beforeEach(async function () {
    await farmCoin
      .connect(accounts[0])
      .approve(staking.address, AMOUNT_TO_STAKE);
  });

  interface CalculateStakeRewardParams {
    stakeToken?: string;
    amount?: BigNumber;
    optionIndex?: number;
  }

  const calcStakeReward = async function ({
    stakeToken = USDCAddr,
    amount = AMOUNT_TO_STAKE,
    optionIndex = 0,
  }: CalculateStakeRewardParams): Promise<BigNumber> {
    const stakeOptions = (await staking.getStakeOptions(stakeToken))[
      optionIndex
    ];
    return stakeOptions.depositeType === DepositTokenType.Immediate
      ? amount.div(10)
      : stakeOptions.depositeType === DepositTokenType.ShortTerm
      ? amount.div(5)
      : amount.mul(10).div(3);
  };

  interface StakeParams {
    signer?: SignerWithAddress;
    stakeToken?: typeof USDCAddr;
    amountToStake?: BigNumber;
    stakeOption?: number;
  }

  const stake = async ({
    signer = accounts[0],
    stakeToken = USDCAddr,
    amountToStake = AMOUNT_TO_STAKE,
    stakeOption = 0,
  }: StakeParams): Promise<ContractTransaction> => {
    return staking
      .connect(signer)
      .stake(stakeToken, amountToStake, stakeOption);
  };

  describe("Staking options", async function () {
    it("Create new option from non staking owner", async function () {
      await expect(
        staking
          .connect(accounts[0])
          .addStakeOptions(
            USDCAddr,
            10,
            10_000,
            farmCoin.address,
            DepositTokenType.Immediate
          )
      ).revertedWith("!tokenStakeOwner");
    });
  });

  describe("Staking Test", function () {
    it("New Stake", async function () {
      expect(await farmCoin.balanceOf(staking.address)).eq(AMOUNT_TO_STAKE);
      await expect(stake({ amountToStake: AMOUNT_TO_STAKE })).reverted;
    });
  });
});
