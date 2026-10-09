# Third-Party Notices

Mila includes, depends on, or downloads at runtime the following third-party software. All notices are reproduced or summarized here in fulfillment of the attribution clauses in their respective licenses.

The list is split between (a) components bundled inside the `Mila.app` binary that we redistribute, and (b) components downloaded by the user from the upstream's own servers when a related feature is used.

---

## A. Bundled in the .app

### whisper.cpp xcframework (MIT)

Used as the on-device Whisper inference engine via TranscriptionCore's Swift binding. Pulled in as a binary Swift Package Manager target.

- Project: https://github.com/ggml-org/whisper.cpp
- License: MIT — https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE
- Copyright © Georgi Gerganov and whisper.cpp contributors.

### Sparkle (MIT)

Used for in-app auto-updates.

- Project: https://github.com/sparkle-project/Sparkle
- License: MIT — https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
- Copyright © Sparkle Project and contributors.

### pyannote/segmentation-3.0 model weights (MIT)

Bundled at `Mila/Resources/DiarizationModels/segmentation-3.0/pytorch_model.bin`. Loaded by the pyannote.audio speaker-diarization pipeline.

- Upstream: https://huggingface.co/pyannote/segmentation-3.0
- License: MIT (per upstream model card).
- Copyright © Hervé Bredin and the pyannote.audio authors.

### pyannote-wespeaker-voxceleb-resnet34-LM model weights

Bundled at `Mila/Resources/DiarizationModels/pyannote-wespeaker-voxceleb-resnet34-LM/pytorch_model.bin`. Loaded as the speaker-embedding model for the diarization pipeline.

- Upstream: https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
- Upstream WeSpeaker code project: https://github.com/wenet-e2e/wespeaker (Apache-2.0)
- License: **CC-BY-4.0** (Creative Commons Attribution 4.0 International), per the
  HuggingFace model card — it follows the VoxCeleb dataset's terms. Redistribution
  of the weights is permitted with attribution, which this notice provides.
- Copyright © the pyannote.audio / WeSpeaker authors and the VoxCeleb dataset creators.

---

## B. Downloaded by the user from a third party at runtime

These components are fetched from the upstream's own CDN or package repository when the relevant feature is used. Mila orchestrates the download but does not redistribute the bytes — the upstream serves them directly. Each component's license attaches at the moment of installation; the upstream packages include their own license texts.

### Whisper model weights — OpenAI (MIT)

`large-v3-turbo` and any other OpenAI Whisper ggml repackagings fetched from `huggingface.co/ggerganov/whisper.cpp`.

- Original project: https://github.com/openai/whisper
- License: MIT — https://github.com/openai/whisper/blob/main/LICENSE
- Copyright © OpenAI.

### Whisper model weights — ivrit.ai (Apache-2.0)

`ivrit-ai/whisper-large-v3-ggml` Hebrew finetune, fetched from `huggingface.co/ivrit-ai`.

- Project: https://www.ivrit.ai / https://huggingface.co/ivrit-ai
- License: Apache-2.0 (per upstream model card).
- Copyright © ivrit.ai.

### PyTorch / torchaudio (BSD-3-Clause)

Wheels fetched on first launch from `download.pytorch.org`. Installed into a user-writable site-packages directory at `~/Library/Application Support/Mila/torch-site-packages/`.

- Project: https://pytorch.org
- License: BSD-3-Clause — https://github.com/pytorch/pytorch/blob/main/LICENSE
- Copyright © Meta Platforms and PyTorch contributors.

### pyannote.audio + transitive dependencies

Installed from PyPI via `pip install` into the bundled Python runtime when diarization is used.

| Package | License | Upstream |
|---|---|---|
| `pyannote.audio` | MIT | https://github.com/pyannote/pyannote-audio |
| `speechbrain` | Apache-2.0 | https://github.com/speechbrain/speechbrain |
| `pytorch-lightning` | Apache-2.0 | https://github.com/Lightning-AI/lightning |
| `huggingface_hub` | Apache-2.0 | https://github.com/huggingface/huggingface_hub |
| `soundfile` | BSD-3-Clause | https://github.com/bastibe/python-soundfile |
| `numpy` | BSD-3-Clause | https://github.com/numpy/numpy |

Each package ships its own license text in its installed distribution metadata; the texts above are included by reference rather than reproduced here.

---

## C. License texts

Full reproductions of the MIT, BSD-3-Clause, and Apache-2.0 license texts are available at their canonical sources:

- MIT: https://opensource.org/license/mit
- BSD-3-Clause: https://opensource.org/license/bsd-3-clause
- Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0

If any attribution above is incomplete or incorrect, please open an issue on the Mila repository — we'll fix it.

<!-- FORK: everything below this line is added by the personal fork (shircomay/mila-sandbox), not by upstream Mila. -->

---

## D. Fork additions

### SpeexDSP echo canceller and preprocessor (BSD-3-Clause) <!-- FORK -->

Vendored as C source in `Packages/EchoCancellation/Sources/CSpeexDSP` (acoustic echo cancellation of the microphone against the meeting audio, and residual-echo suppression). Compiled into the app by the local `EchoCancellation` Swift package.

- Project: https://github.com/xiph/speexdsp (commit `7a158783df74efe7c2d1c6ee8363c1e695c71226`)
- License: BSD-3-Clause (Xiph.Org Foundation licence, reproduced below and in `Packages/EchoCancellation/Sources/CSpeexDSP/COPYING`).
- The vendored files are unmodified; see `Packages/EchoCancellation/Sources/CSpeexDSP/VENDORED.md`.

```
Copyright 2002-2008 	Xiph.org Foundation
Copyright 2002-2008 	Jean-Marc Valin
Copyright 2005-2007	Analog Devices Inc.
Copyright 2005-2008	Commonwealth Scientific and Industrial Research
                        Organisation (CSIRO)
Copyright 1993, 2002, 2006 David Rowe
Copyright 2003 		EpicGames
Copyright 1992-1994	Jutta Degener, Carsten Bormann

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
