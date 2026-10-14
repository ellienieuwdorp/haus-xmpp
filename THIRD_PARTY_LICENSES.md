# Third-party licences

Haus XMPP is distributed under GPL-3.0-or-later with an additional permission
for Apple distribution services (see `LICENSE`, `LICENSE-ADDITIONAL-PERMISSION`).
The app links the components below. Apple system frameworks (SwiftUI, UIKit,
AppKit, Foundation, CryptoKit, CommonCrypto, Security, SQLite, UserNotifications,
Intents, Photos, AVFoundation) are System Libraries under section 1 of the GPL and
are not redistributed by this project.

| Component | Version / pin | Licence | Where |
|---|---|---|---|
| libomemo-c | 0.5.1, `1f0b37fee3ebefc46c32f882623481899a1ba568` | GPL-3.0-only + Apple App Store additional permission | `Packages/OMEMOCrypto/Sources/CLibOMEMO/upstream` |
| curve25519-donna (in libomemo-c) | as vendored | BSD-3-Clause | `upstream/curve25519/curve25519-donna.c` |
| ed25519 ref10 (SUPERCOP, in libomemo-c) | as vendored | Public domain (D. J. Bernstein et al.) | `upstream/curve25519/ed25519/*.c` |
| nacl_sha512 (in libomemo-c) | 20080913 | Public domain (D. J. Bernstein) | `upstream/curve25519/ed25519/nacl_sha512` |
| XEdDSA / VXEdDSA additions (in libomemo-c) | as vendored | under libomemo-c's notice | `upstream/curve25519/ed25519/additions` |
| uthash, utlist, utarray (in libomemo-c) | 2016 | BSD-1-Clause style (Troy D. Hanson) | `upstream/ut*.h` |
| vpool (in libomemo-c) | 2008 | ISC style (Alexey Vatchenko) | `upstream/vpool.c`, `vpool.h` |
| protobuf-c runtime | 1.5.2, `4719fdd7760624388c2c5b9d6759eb6a47490626` | BSD-2-Clause | `Packages/OMEMOCrypto/Sources/CLibOMEMO/protobuf-c` |

---

## libomemo-c

    Copyright 2015-2016 Open Whisper Systems
    Copyright 2020-2025 Dino Team
    
    Licensed under the GPLv3: http://www.gnu.org/licenses/gpl-3.0.html
    
    Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).

Full text: `LICENSE` (identical terms to `Packages/OMEMOCrypto/LICENSE.libomemo-c`).

## curve25519-donna

    Copyright 2008, Google Inc.
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:
    
        * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above
    copyright notice, this list of conditions and the following disclaimer
    in the documentation and/or other materials provided with the
    distribution.
        * Neither the name of Google Inc. nor the names of its
    contributors may be used to endorse or promote products derived from
    this software without specific prior written permission.
    
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    
    curve25519-donna: Curve25519 elliptic curve, public key function
    Derived from public domain C code by Daniel J. Bernstein <djb@cr.yp.to>

## ed25519 ref10 and nacl_sha512

Public domain code by Daniel J. Bernstein, Niels Duif, Tanja Lange, Peter Schwabe and Bo-Yin Yang (SUPERCOP ref10), as included in libomemo-c; the vendored files carry no notice of their own. `nacl_sha512/hash.c` is marked "20080913 D. J. Bernstein Public domain."

## uthash, utlist, utarray

    Copyright (c) 2003-2016, Troy D. Hanson     http://troydhanson.github.com/uthash/
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    
        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
    
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
    IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
    TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
    PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
    OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
    EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
    PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
    LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
    NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

    (utlist.h: Copyright (c) 2007-2016, utarray.h: Copyright (c) 2008-2016, same terms.)

## vpool

    Copyright (c) 2006, 2008 Alexey Vatchenko <av@bsdua.org>
    
    Permission to use, copy, modify, and/or distribute this software for any
    purpose with or without fee is hereby granted, provided that the above
    copyright notice and this permission notice appear in all copies.
    
    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
    WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
    MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
    ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
    WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
    ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
    OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    

## protobuf-c

    Copyright (c) 2008-2025, Dave Benson and the protobuf-c authors.
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:
    
        * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
    
        * Redistributions in binary form must reproduce the above
    copyright notice, this list of conditions and the following disclaimer
    in the documentation and/or other materials provided with the
    distribution.
    
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    
    The code generated by the protoc-gen-c code generator and by the
    protoc-c compiler is owned by the owner of the input files used when
    generating it. This code is not standalone and requires a support
    library to be linked with it. This support library is covered by the
    above license.
