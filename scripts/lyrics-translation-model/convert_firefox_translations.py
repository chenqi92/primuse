"""Convert a Mozilla Firefox Translations tiny or base-memory student
(Marian transformer encoder + SSRU decoder) into a Core ML package with
encode and decode functions. Embedding width, vocabulary sizes and decoder
depth come from the weights; source and target embeddings can be separate.

A token one past the target vocabulary is Marian's start symbol, whose
embedding is zero. Weights are stored as per-channel int8; computation stays
in float32 because float16 drifts over the decoding steps (see README).

usage: convert_firefox_translations.py <final.model.npz.best-chrf.npz> <out.mlpackage>
"""
import math
import os
import re
import shutil
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

DIM = 256
HEADS = 8
MAX_SOURCE = 256


def sinusoid_at(positions, dim):
    """Marian's sinusoidal position embedding: sines then cosines."""
    i = torch.arange(dim // 2, dtype=torch.float32)
    inv = 1.0 / torch.pow(10000.0, (2.0 * i) / dim)
    v = positions[:, None] * inv[None, :]
    return torch.cat([torch.sin(v), torch.cos(v)], dim=-1)


class LayerNorm(nn.Module):
    def __init__(self, scale, bias):
        super().__init__()
        self.scale = nn.Parameter(scale.view(-1))
        self.bias = nn.Parameter(bias.view(-1))

    def forward(self, x):
        mu = x.mean(-1, keepdim=True)
        var = ((x - mu) ** 2).mean(-1, keepdim=True)
        return self.scale * (x - mu) / torch.sqrt(var + 1e-6) + self.bias


def linear(weight, bias=None):
    layer = nn.Linear(weight.shape[0], weight.shape[1], bias=bias is not None)
    layer.weight.data = weight.T.contiguous()
    if bias is not None:
        layer.bias.data = bias.view(-1)
    return layer


class Attention(nn.Module):
    """Multi-head attention with Marian's post-norm residual ("dan")."""

    def __init__(self, p, prefix):
        super().__init__()
        self.q = linear(p[prefix + "_Wq"], p[prefix + "_bq"])
        self.k = linear(p[prefix + "_Wk"], p[prefix + "_bk"])
        self.v = linear(p[prefix + "_Wv"], p[prefix + "_bv"])
        self.o = linear(p[prefix + "_Wo"], p[prefix + "_bo"])
        self.norm = LayerNorm(p[prefix + "_Wo_ln_scale"], p[prefix + "_Wo_ln_bias"])

    def forward(self, query, keys):
        # Batch is always 1; reshapes avoid traced sizes so the source length
        # stays flexible in Core ML.
        dk = DIM // HEADS
        q = self.q(query).reshape(1, -1, HEADS, dk).transpose(1, 2)
        k = self.k(keys).reshape(1, -1, HEADS, dk).transpose(1, 2)
        v = self.v(keys).reshape(1, -1, HEADS, dk).transpose(1, 2)
        attended = torch.softmax((q @ k.transpose(-1, -2)) * (1.0 / math.sqrt(dk)), -1) @ v
        return self.norm(self.o(attended.transpose(1, 2).reshape(1, -1, DIM)) + query)


class FeedForward(nn.Module):
    def __init__(self, p, prefix):
        super().__init__()
        self.w1 = linear(p[prefix + "_ffn_W1"], p[prefix + "_ffn_b1"])
        self.w2 = linear(p[prefix + "_ffn_W2"], p[prefix + "_ffn_b2"])
        self.norm = LayerNorm(p[prefix + "_ffn_ffn_ln_scale"], p[prefix + "_ffn_ffn_ln_bias"])

    def forward(self, x):
        return self.norm(self.w2(torch.relu(self.w1(x))) + x)


class Encoder(nn.Module):
    def __init__(self, p):
        super().__init__()
        self.embedding = p.get("encoder_Wemb", p.get("Wemb"))
        self.attention = nn.ModuleList([Attention(p, f"encoder_l{l}_self") for l in range(1, 7)])
        self.ffn = nn.ModuleList([FeedForward(p, f"encoder_l{l}") for l in range(1, 7)])

    def forward(self, input_ids):
        ids = input_ids.long()
        positions = torch.cumsum(torch.ones_like(ids[0], dtype=torch.float32), 0) - 1.0
        x = self.embedding[ids] * math.sqrt(DIM) + sinusoid_at(positions, DIM)[None]
        for attention, ffn in zip(self.attention, self.ffn):
            x = ffn(attention(x, x))
        return x


class Decoder(nn.Module):
    """One step: SSRU (c = f·c' + (1−f)·Wx, h = relu(c)), cross-attention, FFN."""

    def __init__(self, p):
        super().__init__()
        self.embedding = p.get("decoder_Wemb", p.get("Wemb"))
        self.depth = sum(re.fullmatch(r"decoder_l\d+_rnn_W", name) is not None for name in p)
        layers = range(1, self.depth + 1)
        self.vocab = self.embedding.shape[0]
        self.cell = nn.ModuleList([linear(p[f"decoder_l{l}_rnn_W"]) for l in layers])
        self.forget = nn.ModuleList([linear(p[f"decoder_l{l}_rnn_Wf"], p[f"decoder_l{l}_rnn_bf"]) for l in layers])
        self.cell_norm = nn.ModuleList([
            LayerNorm(p[f"decoder_l{l}_rnn_ffn_ln_scale"], p[f"decoder_l{l}_rnn_ffn_ln_bias"]) for l in layers
        ])
        self.context = nn.ModuleList([Attention(p, f"decoder_l{l}_context") for l in layers])
        self.ffn = nn.ModuleList([FeedForward(p, f"decoder_l{l}") for l in layers])
        self.output_bias = nn.Parameter(p["decoder_ff_logit_out_b"].view(-1))

    def forward(self, token, position, *inputs):
        states, encoder_out = inputs[:-1], inputs[-1]
        token = token.long()
        is_start = (token >= self.vocab).float()[:, None]
        embedded = self.embedding[torch.clamp(token, max=self.vocab - 1)] * (1.0 - is_start)
        x = embedded * math.sqrt(DIM) + sinusoid_at(position.float(), DIM)
        new_states = []
        for i in range(self.depth):
            f = torch.sigmoid(self.forget[i](x))
            c = f * states[i] + (1 - f) * self.cell[i](x)
            new_states.append(c)
            x = self.cell_norm[i](torch.relu(c) + x)
            x = self.context[i](x[:, None, :], encoder_out)[:, 0, :]
            x = self.ffn[i](x)
        logits = x @ self.embedding.T + self.output_bias
        return (logits, *new_states)


def load(path):
    z = np.load(path)
    return {k: torch.from_numpy(z[k].astype(np.float32)) for k in z.files if not k.startswith("special")}


def main():
    global DIM
    npz, out = sys.argv[1], sys.argv[2]
    p = load(npz)
    embedding = p.get("encoder_Wemb", p.get("Wemb"))
    DIM = int(embedding.shape[1])
    if DIM % HEADS != 0:
        raise ValueError("Embedding width must divide into eight attention heads")
    encoder = Encoder(p).eval()
    decoder = Decoder(p).eval()
    for module in (encoder, decoder):
        for parameter in module.parameters():
            parameter.requires_grad_(False)

    length = 12
    ids = torch.randint(0, encoder.embedding.shape[0], (1, length), dtype=torch.int32)
    with torch.no_grad():
        encoded = encoder(ids)
        traced_encoder = torch.jit.trace(encoder, (ids,))
        start = torch.tensor([decoder.vocab], dtype=torch.int32)
        zero_position = torch.tensor([0], dtype=torch.int32)
        zero_states = tuple(torch.zeros(1, DIM) for _ in range(decoder.depth))
        traced_decoder = torch.jit.trace(decoder, (start, zero_position, *zero_states, encoded))

    source = ct.RangeDim(lower_bound=1, upper_bound=MAX_SOURCE, default=length)
    common = dict(
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
    )
    encode = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType("input_ids", shape=(1, source), dtype=np.int32)],
        outputs=[ct.TensorType("encoder_out", dtype=np.float32)],
        **common,
    )
    decode = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType("token", shape=(1,), dtype=np.int32),
            ct.TensorType("position", shape=(1,), dtype=np.int32),
            *[ct.TensorType(f"state{i+1}", shape=(1, DIM), dtype=np.float32) for i in range(decoder.depth)],
            ct.TensorType("encoder_out", shape=(1, source, DIM), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType("logits", dtype=np.float32),
            *[ct.TensorType(f"state{i+1}_out", dtype=np.float32) for i in range(decoder.depth)],
        ],
        **common,
    )
    quantization = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode="linear_symmetric", granularity="per_channel", weight_threshold=2048
    ))
    encode = linear_quantize_weights(encode, quantization)
    decode = linear_quantize_weights(decode, quantization)

    parts = out + ".parts"
    os.makedirs(parts, exist_ok=True)
    encode.save(f"{parts}/encode.mlpackage")
    decode.save(f"{parts}/decode.mlpackage")
    descriptor = ct.utils.MultiFunctionDescriptor()
    descriptor.add_function(f"{parts}/encode.mlpackage", src_function_name="main", target_function_name="encode")
    descriptor.add_function(f"{parts}/decode.mlpackage", src_function_name="main", target_function_name="decode")
    descriptor.default_function_name = "decode"
    if os.path.exists(out):
        shutil.rmtree(out)
    ct.utils.save_multifunction(descriptor, out)
    shutil.rmtree(parts)
    print("saved", out)


if __name__ == "__main__":
    main()
