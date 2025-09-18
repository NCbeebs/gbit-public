# gbit-public
https://goldenbit.org/ Currently deployed Golden Bit contract
---

## Golden Bit - Project Summary

GBIT is a decentralized elimination style game built on Ethereum smart contracts that combines fair randomness with NFT trading mechanics. Players claim unique ticket NFTs representing positions on a 256-slot game board, with the objective of being the last remaining ticket holder to win the accumulated prize pool.

## Game Mechanics

The game operates through a multi-round elimination system. Players initially claim tickets for free (gas fees only), with the game starting once all 256 positions are claimed. Each round lasts 15 minutes, at the end of which half of the active tickets are randomly eliminated using Chainlink VRF for provable fairness. Between rounds, players can trade tickets through an integrated marketplace, listing tickets for sale or making offers on others' positions. The game continues until only one ticket remains, with that holder winning the entire prize pool.

## Market Mechanics

NFT tickets owned by players can be listed for sale or have offers created on them by other players. Offer amounts are held in escrow by the contract. If the offer is rejected, or canceled at the end of a round before elimination, the offer maker can retrieve their offer amount. This ensures accepting offers can pay the original ticket owner instantly and transfer ticket ownership without requiring additional verification. A certain percentage of ticket transfers are transferred to the pot - this is how the ultimate winners pot is built. More engagement leads to a higher prize pool. Prize pool can also be seeded manually via `receive()`.

## Smart Contract Architecture

The system is built on a gas-optimized Solidity contract using OpenZeppelin's upgradeable framework. Key technical features include:

- **ERC721 NFT Standard**: Each ticket is a unique, tradeable NFT
- **Bitfield Storage**: Efficient boolean flag management for game state
- **Hybrid Data Structures**: Optimized mappings for position/token relationships
- **Chainlink VRF**: Provides the random seed for eliminations
- **Chainlink Automation**: Controls game logic execution
- **Pull Payment Pattern**: Secure withdrawal mechanism for funds
- **Reentrancy Protection**: Comprehensive security against common attack vectors

The contract implements a sophisticated marketplace with automatic fee distribution (10% to prize pool, 10% to dealer, 80% to seller) and includes emergency controls for administrative oversight.

## Why Ethereum Smart Contracts

Ethereum smart contracts provide the ideal foundation for this project through several critical advantages:

- **Transparency and Trust**: All game logic, randomness generation, and fund distribution are publicly verifiable on-chain, eliminating concerns about manipulation or hidden mechanics.
- **Decentralization**: No central authority controls the game flow or can interfere with outcomes, ensuring fair play for all participants.
- **Programmable Money**: Smart contracts enable automatic fee distribution, escrow functionality, and complex trading mechanics without requiring trusted intermediaries.

## Frontend Integration

The React-based frontend serves as the user interface layer, providing real-time game state visualization and interaction capabilities. Key frontend components include:

- **Web3 Integration**: Seamless wallet connection and transaction management through ethers.js, supporting MetaMask and other Web3 wallets.
- **Interactive Game Board**: Visual representation of all 256 ticket positions with real-time status updates, filtering, and sorting capabilities.
- **Marketplace Interface**: Direct integration with smart contract functions for listing, purchasing, and making offers on tickets.
- **Multi-environment Support**: Automatic configuration switching between local development, testnet, and mainnet deployments.

