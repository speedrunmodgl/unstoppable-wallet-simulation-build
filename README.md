# Unstoppable Wallet personal simulation — native build

Unofficial work-in-progress iOS simulation. It has not yet been compiled or tested.
Virtual funds have no monetary value; the target does not use real-wallet signing
or blockchain transaction broadcasting. It uses public Coinbase Exchange price
data where available. Do not use it for financial decisions.

The native project is `Unstoppable/Simulation.xcodeproj`, scheme `Simulation`.
The manual workflow builds with Xcode on a GitHub-hosted macOS runner and is
intended to produce an unsigned iPhone IPA as a publicly downloadable prerelease;
a device build must be signed and provisioned before installation. Source, workflow
logs, and releases are public. The workflow and output have not yet been verified.

The original Unstoppable Wallet project and original app icon are copyright
Horizontal Systems; see `LICENSE` for the MIT license notice. This is not an
official application.
