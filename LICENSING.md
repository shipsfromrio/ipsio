# Licensing

Ipsio is dual-licensed.

## The source in this repository: GPL-3.0

Everything in this repository is free software under the GNU General Public
License, version 3 (see [`LICENSE`](LICENSE)). You may use, study, change and
share it under those terms. Building it yourself (`install.sh`,
`install-app.sh`, or `build-store.sh` for a sandboxed build) gives you every
feature with no trial and no purchase: the GPL build is always unlocked.

## The Mac App Store edition: a separate license

The copy sold on the Mac App Store is built from the same source with
`-D STORE`. It is distributed under the copyright holder's own terms and the
App Store's standard license agreement, because the App Store's terms of use
are not compatible with the GPL. The App Store edition adds no hidden code:
what differs is the build flag (no `POST_RECORDING` hook, no
`CALENDAR_COMMAND`, the trial and the in-app purchase) and the signature.

Buying the App Store edition pays for the convenience of a signed, sandboxed,
updated build, and supports the project. It does not take any right away
from the GPL source.

## Contributions

The dual license is only possible while one holder owns the copyright of
every line. So a contribution (pull request, patch) is accepted only with the
contributor's agreement, stated in the pull request, that:

1. the contribution is their own original work, or they have the right to
   submit it; and
2. they license it to the project under the GPL-3.0 **and** grant the
   copyright holder a perpetual, worldwide, royalty-free, irrevocable license
   to use, change and distribute it under other terms, including in the
   App Store edition.

Write in the pull request: "I agree to the contribution terms in
LICENSING.md." Without it, the pull request is not merged.

## Third-party software

The App Store edition contains no third-party code. The GPL edition's
optional legacy script (`ipsio.sh`) uses ffmpeg and the BlackHole driver, which
are installed separately by the user under their own licenses and are not part
of the App Store edition.
