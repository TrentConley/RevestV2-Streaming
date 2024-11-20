# RevestV2

Working Repo for Version R2 of the Revest Protocol with token streaming.

Simply run `forge build` to compile with foundry and `forge test` to run all tests.

## Overview

**Token Streaming Via Revest FNFTs 🏅**

I built a way to stream tokens using the Revest FNFTs. This includes two different methods for streaming tokens within the FNFTs: **quadratic** and **linear**. By modifying the RevestV2 contracts, I introduced a batch minting process that creates one FNFT for each second between the creation date and the expiration of the time lock. This approach allows users to withdraw tokens seamlessly at predetermined intervals.

### Key Features

1. **Linear Streaming (`withdrawFNFTSteam`)**:

   - Calculates the quantity of FNFTs to withdraw based on the time elapsed since creation.
   - Burns the calculated quantity of FNFTs from the user's balance.
   - Updates the withdrawn amount and last withdrawn time for the FNFT.

2. **Quadratic Streaming (`withdrawFNFTSteamQuadratic`)**:
   - Calculates the quantity of FNFTs to withdraw using a quadratic formula.
   - Burns the calculated quantity of FNFTs from the user's balance.
   - Updates the withdrawn amount and last withdrawn time for the FNFT.

### Testing

Comprehensive tests were written to ensure the reliability of the withdrawal functions:

1. **Linear Withdrawal Test (`testWithdrawFNFTSteam`)**:

   - Mints a new FNFT with a time lock.
   - Simulates the passage of time.
   - Verifies that the user's balance increases as expected and that the FNFT supply decreases correctly.

2. **Quadratic Withdrawal Test (`testWithdrawFNFTSteamQuadratic`)**:

   - Mints a new FNFT with a time lock.
   - Simulates the passage of time.
   - Verifies that the user's balance increases by the expected quadratic amount and that the FNFT supply decreases correctly.

3. **Quadratic Withdrawal with Offset (`testWithdrawFNFTSteamQuadraticOffset`)`**
   - Mints a new FNFT with a time lock and an offset.
   - Simulates the passage of time.
   - Verifies that the user's balance increases appropriately based on the offset and that the FNFT supply decreases correctly.

Additional modifications were made to support these functionalities, such as bypassing the lock manager and updating interfaces.

## Team

**Solo Project**

## Challenges

### Web3 ATL Hackathon by 404 DAO

- **Project Submitted**: Token Streaming Via Revest FNFTs
- **Challenges Won**: Revest Challenge
- **Prize**: Initially $2,500 USD, which increased to over $7,000 in Ethereum at distribution time for first place.

## Documentation

- [V2 Developer Docs](https://revest-finance.gitbook.io/revestv2-developer-documentation/)
- [Revest User Documentation](https://docs.revest.finance/)
- [V1 Developer Docs](https://docs.revest.finance/)

## Getting Started

To build and test the project, ensure you have Foundry installed. Then run:

```bash
forge build
forge test
```

## License

This project is licensed under the GNU-GPL v3.0 or later.

## Contact

For any inquiries or contributions, please contact [Trent Conley](https://github.com/TrentConley).

## Acknowledgements

- [Revest Finance](https://revest.finance/)
- [Foundry](https://github.com/foundry-rs/foundry)
- [404 DAO](https://www.404dao.com/)
