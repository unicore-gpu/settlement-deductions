# Settlement Deductions

A draft ERC and reference implementation for withholding part of an escrowed payment
(a tax, a referral fee, a loan repayment) at the moment it is paid out, without the
escrow knowing any of the rules and without ever blocking the payment.

```
payout 100
 ├─ tax 1%        → treasury   1
 ├─ referral 2%   → referrer   2
 ├─ repayment     → lender    30
 └─ payee                     67
```

The escrow names one **deduction policy** for its lifetime and asks it one question at
every payout: how much of this payment do you take? It pays the payee the rest and credits
the amount taken to the policy, which divides it among its recipients. A failing or
misbehaving policy is skipped and the payee is paid in full.

The specification is in [ERC-draft.md](ERC-draft.md). Status: **Draft**, not yet submitted
to [ethereum/ERCs](https://github.com/ethereum/ERCs).

## Contents

| Path | What it is |
|---|---|
| `src/interfaces/ISettlementDeductions.sol` | The policy interface and the escrow's credit interface (`ISettlementCredit`) |
| `src/interfaces/ISettlementDeductionPolicy.sol` | The optional reference-policy profile |
| `src/interfaces/ITaxSchedule.sol` | A tax schedule the reference policy reads at task creation |
| `src/SettlementDeductionPolicy.sol` | Reference policy: tax locked per task, payee-made assignments only their recipient can release, one cap, permissionless claims |
| `src/examples/ExampleEscrow.sol` | The smallest escrow meeting the escrow requirements, with partial payouts and refunds (illustration only) |
| `test/` | Foundry unit, fuzz and invariant tests: every normative rule, the worked example, cap carry-over, partial payouts, refunds, release, withdrawal by third parties, failing, starved and noisy policies, re-entry, interface identifiers |

An ERC-8414 (token-bound task tenders) contract with the escrow side built in lives in the `settlement-deductions`
branch of [unicore-gpu/task-token-standard](https://github.com/unicore-gpu/task-token-standard/tree/settlement-deductions).

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```sh
git clone --recursive https://github.com/unicore-gpu/settlement-deductions
cd settlement-deductions
forge test
```

## Status and warnings

This is a draft standard. The interfaces may change during discussion. The code has not
been audited; do not use it to hold real funds.

Discussion: link to follow (Ethereum Magicians).

## License

[CC0 1.0](LICENSE).
