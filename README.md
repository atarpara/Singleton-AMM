# Singleton Constant Product AMM

A minimalist implementation of a Constant Product Automated Market Maker (AMM) using the Singleton pattern. This smart contract enables multi-hop, gas-efficient token swapping with a single liquidity pool.

## Overview

This project implements a simple yet efficient AMM that:
- Uses the constant product formula (x * y = k)
- Manages a single pair of tokens
- Features atomic swaps
- Implements liquidity provider functionality
- Uses the Singleton pattern to ensure only one instance exists

## Key Features

- **Single Liquidity Pool**: Manages one token pair efficiently
- **Constant Product Formula**: Ensures price stability and liquidity
- **LP Tokens**: Mints/burns tokens for liquidity providers
- **Atomic Swaps**: Executes trades in a single transaction