"""A small GPT for the scaling workload: the compute pattern of LLM training (attention + MLP,
bf16 autocast, AdamW) at a size that fits any single GPU, on synthetic tokens so nothing is
downloaded and every rank sees the same statistics."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import torch
import torch.nn as nn
import torch.nn.functional as F


@dataclass
class GPTConfig:
    n_layer: int = 12
    n_head: int = 12
    n_embd: int = 768
    block_size: int = 1024
    vocab: int = 50304

    def to_dict(self) -> dict:
        return asdict(self)


class Block(nn.Module):
    def __init__(self, c: GPTConfig):
        super().__init__()
        self.ln1 = nn.LayerNorm(c.n_embd)
        self.attn = nn.Linear(c.n_embd, 3 * c.n_embd, bias=False)
        self.proj = nn.Linear(c.n_embd, c.n_embd, bias=False)
        self.ln2 = nn.LayerNorm(c.n_embd)
        self.fc = nn.Linear(c.n_embd, 4 * c.n_embd, bias=False)
        self.fc2 = nn.Linear(4 * c.n_embd, c.n_embd, bias=False)
        self.n_head = c.n_head

    def forward(self, x):
        b, t, d = x.shape
        q, k, v = self.attn(self.ln1(x)).split(d, dim=2)
        q = q.view(b, t, self.n_head, d // self.n_head).transpose(1, 2)
        k = k.view(b, t, self.n_head, d // self.n_head).transpose(1, 2)
        v = v.view(b, t, self.n_head, d // self.n_head).transpose(1, 2)
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        x = x + self.proj(y.transpose(1, 2).reshape(b, t, d))
        return x + self.fc2(F.gelu(self.fc(self.ln2(x))))


class GPT(nn.Module):
    def __init__(self, c: GPTConfig):
        super().__init__()
        self.c = c
        self.wte = nn.Embedding(c.vocab, c.n_embd)
        self.wpe = nn.Embedding(c.block_size, c.n_embd)
        self.blocks = nn.ModuleList(Block(c) for _ in range(c.n_layer))
        self.ln_f = nn.LayerNorm(c.n_embd)
        self.head = nn.Linear(c.n_embd, c.vocab, bias=False)
        self.head.weight = self.wte.weight
        self.apply(self._init)

    def _init(self, m):
        if isinstance(m, nn.Linear | nn.Embedding):
            nn.init.normal_(m.weight, std=0.02 / math.sqrt(2 * self.c.n_layer))

    def forward(self, idx, targets=None):
        b, t = idx.shape
        pos = torch.arange(t, device=idx.device)
        x = self.wte(idx) + self.wpe(pos)
        for blk in self.blocks:
            x = blk(x)
        logits = self.head(self.ln_f(x))
        loss = (
            F.cross_entropy(logits.view(-1, logits.size(-1)), targets.view(-1))
            if targets is not None
            else None
        )
        return logits, loss

    def n_params(self) -> int:
        return sum(p.numel() for p in self.parameters())


def synthetic_batch(batch: int, block: int, vocab: int, device, gen: torch.Generator | None = None):
    idx = torch.randint(0, vocab, (batch, block + 1), device=device, generator=gen)
    return idx[:, :-1].contiguous(), idx[:, 1:].contiguous()
