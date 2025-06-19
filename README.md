# YieldWield v1

A yield re-routing plug-in that enables protocols to offer **yield-backed advances** to their users by leveraging idle stablecoin yield. YieldWield handles share logic, debt tracking, and yield accrual, while **your protocol handles all token transfers and fund custody**.

---

## ✨ What It Does

YieldWield plugs into your protocol to:

* Enable users to take **instant advances** against their future yield.
* Track user **collateral**, **debt**, and **yield growth** using Aave’s liquidity index.
* Let yield **auto-pay down debt** over time—or let users repay manually.
* Enforce **collateral lockups** until debt is cleared.
* Accrue and isolate **protocol revenue** from advance fees.

All logic, no custody.
**You move the tokens. YieldWield keeps score.**

---

## 🛠️ Installation (Forge)

To install YieldWield into your Foundry project:

```bash
forge install X-O1/yieldwield
```

If you’re using scoped packages or need to prevent an auto-commit:

```bash
forge install X-O1/yieldwield --no-commit
```

Once installed, import the contract in your code like this:

```solidity
import "@YieldWield/src/YieldWield.sol";
```

Make sure your `remappings.txt` includes the correct alias if needed:

```
@YieldWield/=lib/YieldWield/
```

---

## 📡 Use the Interface

Your protocol doesn't need to interact with the full `YieldWield` contract directly. For cleaner integration, import and use the provided interface:

```solidity
import "@YieldWield/src/interfaces/IYieldWield.sol";
```

This gives you access to the external functions your protocol needs, with no need to compile the full implementation. Useful for mocks, testing, and cleaner dependency management.

---

## 🚀 Integration Overview

### 1. You Custody the Funds

You own the funds. YieldWield never transfers tokens. All transfers (deposits, withdrawals, repayments) must happen in your protocol.

### 2. Collateral + Advance Flow

When a user takes an advance:

* You deposit the user's idle yield-generating stablecoins (e.g. aUSDC).
* You call `getAdvance()` on YieldWield.
* YieldWield tracks the collateral, computes shares, adds protocol fee, and returns the net advance.

You then send the user the actual tokens for the advance on your end.

### 3. Yield Auto-Repayment

You can:

* Call `getAndupdateAccountDebtFromYield()` to let the user's yield pay down debt over time.
* Or allow the user to call `repayAdvanceWithDeposit()` to repay manually.

Once their debt is zero, they can withdraw via `withdrawCollateral()`.

---

## 📊 State Model

All tracked by protocol > user > token:

* `s_collateralShares` → share-based accounting of a user's deposited collateral
* `s_debt` → current debt owed (after fee)
* `s_accountYield` → how much yield their collateral has earned
* `s_totalRevenueShares` → protocol-owned shares from advance fees

---

## ⚖️ Example Advance Flow

```solidity
IERC20(aToken).transferFrom(user, protocol, amount);
uint256 netAdvance = yieldWield.getAdvance(user, aToken, collateralAmount, requestedAdvance);
// You now send netAdvance to the user from your treasury
```

## ⚖️ Example Yield Repayment Flow

```solidity
uint256 newDebt = yieldWield.getAndupdateAccountDebtFromYield(user, aToken);
```

## ⚖️ Example Repayment via Deposit

```solidity
IERC20(aToken).transferFrom(user, protocol, amount);
yieldWield.repayAdvanceWithDeposit(user, aToken, amount);
```

---

## 🚫 What It Does *Not* Do

* YieldWield **does not store** tokens
* YieldWield **does not handle** actual transfers
* YieldWield **does not verify balances**

That’s all on your end.

---

## 🌟 Recommended Usage

* Use with yield-bearing stablecoins like aUSDC or aDAI
* Limit advance amounts to prevent undercollateralization
* Use `getShareValue()` to convert shares to real token values anytime
* Track and claim revenue using `claimRevenue()`

---

## ⚙️ Contract Deployment

```solidity
new YieldWield(addressesProvider);
```

Where `addressesProvider` is Aave v3's PoolAddressesProvider (e.g. for mainnet).

---

## 🔮 Coming in V2: YieldWield Marketplace

V2 will evolve YieldWield into a full marketplace for DeFi power users to fund advances, set custom terms, and earn above-market yield by backing future yield claims.

---

## ✉️ Need Help?

Open an issue or contact the original developer:
Email: [yieldwield@protonmail.com](mailto:yieldwield@protonmail.com)
X (formally Twitter): [https://x.com/YieldWield\_com](https://x.com/YieldWield_com)
