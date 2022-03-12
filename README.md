# Documents

Lockup staking smart contracts.

# Running Method

```shell
npm install
npx hardhat compile
npx hardhat test
npx hardhat run --network ropsten scripts/deploy.ts
npx hardhat verify --network ropsten FarmCoin_Address
npx hardhat verify  --network ropsten Staking_Address "USDCAddr" "FarmCoin_Addr"
```
