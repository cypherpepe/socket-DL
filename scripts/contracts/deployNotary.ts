import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { Contract, ContractFactory } from "ethers";
import { getChainId } from "../utils";

export default async function deployNotary(signatureVerifier: Contract, signer: SignerWithAddress) {
  try {
    const chainId = await getChainId();

    const Notary: ContractFactory = await ethers.getContractFactory("AdminNotary");
    const notaryContract: Contract = await Notary.connect(signer).deploy(signatureVerifier.address, chainId);
    await notaryContract.deployed();

    return notaryContract;
  } catch (error) {
    throw error;
  }
}