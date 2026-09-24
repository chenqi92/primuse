#!/usr/bin/env python3
"""Converts Hybrid Transformer Demucs (vocals only) to the Core ML model the
karaoke mode downloads.

The STFT stays outside the model: Core ML has no complex tensors, and the
app computes the spectrogram with `KaraokeDemucsSpectrogram`, which mirrors
Demucs exactly. The model takes the complex-as-channels spectrogram and the
waveform of one 7.8 s stereo segment and returns the vocals of both
branches.

Tested with torch 2.5.0 (CPU), coremltools 8.3.0, demucs 4.0.1:

    python3 -m venv env
    env/bin/pip install --index-url https://download.pytorch.org/whl/cpu torch==2.5.0 torchaudio==2.5.0
    env/bin/pip install coremltools==8.3.0 demucs==4.0.1 numpy
    env/bin/python convert_htdemucs.py --output HTDemucsVocals.mlpackage
"""
import argparse
import shutil

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from demucs.pretrained import get_model
from einops import rearrange


# coremltools 8.3 raises on torch `int()` of a one-element constant array.
@register_torch_op(torch_alias=["int"], override=True)
def _int(context, node):
    x = context[node.inputs[0]]
    if x.val is not None:
        context.add(mb.const(val=np.int32(int(np.asarray(x.val).reshape(-1)[0])), name=node.name))
    else:
        context.add(mb.cast(x=x, dtype="int32", name=node.name))


class VocalCore(nn.Module):
    """HTDemucs.forward between `_spec` and `_mask`, vocals only."""

    def __init__(self, model):
        super().__init__()
        self.m = model
        self.si = model.sources.index("vocals")

    def forward(self, mag, mix):
        m = self.m
        x = mag
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)
        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T) * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1]) * stdt[:, None] + meant[:, None]
        return x[:, self.si], xt[:, self.si]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="HTDemucsVocals.mlpackage")
    parser.add_argument("--model", default="htdemucs")
    args = parser.parse_args()

    bag = get_model(args.model)
    model = (bag.models[0] if hasattr(bag, "models") else bag).eval()
    core = VocalCore(model).eval()
    # The fused attention kernel has no Core ML equivalent.
    torch.backends.mha.set_fastpath_enabled(False)

    length = int(float(model.segment) * model.samplerate)  # 343980
    mix = torch.randn(1, 2, length) * 0.1
    with torch.no_grad():
        mag = model._magnitude(model._spec(mix))
        traced = torch.jit.trace(core, (mag, mix), check_trace=False)

    # float32 I/O keeps the app's reads on the fast path; compute is fp16
    # on the GPU. The Neural Engine overflows in the frequency branch, so
    # the app pins the model to CPU+GPU.
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="spec", shape=mag.shape, dtype=np.float32),
            ct.TensorType(name="mix", shape=mix.shape, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="vocals_spec", dtype=np.float32),
            ct.TensorType(name="vocals_wave", dtype=np.float32),
        ],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.short_description = "Hybrid Transformer Demucs v4 (vocals), Meta Platforms, MIT License"
    shutil.rmtree(args.output, ignore_errors=True)
    mlmodel.save(args.output)
    print("saved", args.output)


if __name__ == "__main__":
    main()
