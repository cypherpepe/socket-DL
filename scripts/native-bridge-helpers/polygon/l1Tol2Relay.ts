import { config as dotenvConfig } from "dotenv";
dotenvConfig();

import fs from "fs";
import { Contract, providers, Wallet } from "ethers";
import { arrayify, defaultAbiCoder, keccak256 } from "ethers/lib/utils";

import { getInstance, deployedAddressPath } from "../../deploy/utils";
import { packPacketId } from "../../deploy/scripts/packetId";
import { getJsonRpcUrl, contractNames } from "../../constants";
import { mode } from "../../deploy/config";
import { ChainKey, chainKeyToSlug, ChainSocketAddresses } from "../../../src";

// get providers for source and destination
const localChain = ChainKey.GOERLI;
const remoteChain = ChainKey.POLYGON_MUMBAI;
const outboundTxHash = "";

const walletPrivateKey = process.env.SOCKET_SIGNER_KEY!;
const l1Provider = new providers.JsonRpcProvider(getJsonRpcUrl(localChain));

const l1Wallet = new Wallet(walletPrivateKey, l1Provider);

export const main = async () => {
  try {
    if (!fs.existsSync(deployedAddressPath(mode))) {
      throw new Error("addresses.json not found");
    }
    const addresses = JSON.parse(
      fs.readFileSync(deployedAddressPath(mode), "utf-8")
    );

    if (
      !addresses[chainKeyToSlug[localChain]] ||
      !addresses[chainKeyToSlug[remoteChain]]
    ) {
      throw new Error("Deployed Addresses not found");
    }

    const l1Config: ChainSocketAddresses =
      addresses[chainKeyToSlug[localChain]];
    const contracts = contractNames("", localChain, remoteChain);

    const l1Capacitor: Contract = (
      await getInstance(
        "SingleCapacitor",
        l1Config["integrations"]?.[chainKeyToSlug[remoteChain]]?.[
          contracts.integrationType
        ]?.["capacitor"]
      )
    ).connect(l1Wallet);

    const l1Notary: Contract = (
      await getInstance(
        contracts.notary,
        l1Config[contracts.notary]?.[chainKeyToSlug[remoteChain]]
      )
    ).connect(l1Wallet);

    // outbound
    const outboundTxReceipt = await l1Provider.getTransactionReceipt(
      outboundTxHash
    );

    // seal
    const { packetId, newRootHash } = l1Capacitor.interface.decodeEventLog(
      "MessageAdded",
      outboundTxReceipt.logs[1].data
    );

    const packedPacketId = packPacketId(
      chainKeyToSlug[localChain],
      l1Capacitor.address,
      packetId
    );

    const digest = keccak256(
      defaultAbiCoder.encode(
        ["uint256", "uint256", "bytes32"],
        [chainKeyToSlug[remoteChain], packedPacketId, newRootHash]
      )
    );
    const signature = await l1Wallet.signMessage(arrayify(digest));
    const bridgeParams = [];

    const sealTx = await l1Notary.seal(
      l1Capacitor.address,
      bridgeParams,
      signature
    );
    const sealTxReceipt = await sealTx.wait();

    // wait for msg to arrive on l2
    console.log(
      `Seal txn confirmed on L1! 🙌 ${sealTxReceipt.transactionHash}`
    );
  } catch (error) {
    console.log("Error while sending transaction", error);
    throw error;
  }
};

main()
  .then(() => process.exit(0))
  .catch((error: Error) => {
    console.error(error);
    process.exit(1);
  });
