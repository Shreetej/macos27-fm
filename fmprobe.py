#!/usr/bin/env python3
"""
fmprobe.py — characterise Apple's on-device Foundation Model against local frameworks.

Separate from bench.py, which is frozen as the before/after artifact. Stdlib only.

  python3 fmprobe.py ceiling      # binary-search the real context limit
  python3 fmprobe.py maxtokens    # does the server honour max_tokens?
  python3 fmprobe.py curve        # TTFT / decode vs prompt length, all backends
  python3 fmprobe.py schema       # constrained JSON output, validity + latency
  python3 fmprobe.py concurrency  # does throughput scale with parallel requests?
  python3 fmprobe.py coldstart    # first-token cost after an idle period

Everything writes JSON to fmprobe-out/<name>.json so claims stay traceable.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "fmprobe-out"

# Peers chosen to be the same size class as Apple's on-device model (~3B, third-party
# reported). All are instruct builds so none of them emit reasoning traces.
BACKENDS = {
    "apple-fm": {"url": "http://127.0.0.1:1976/v1", "model": "system"},
    "omlx-qwen3-4b": {"url": "http://127.0.0.1:8005/v1",
                      "model": "Qwen3-4B-Instruct-2507-4bit-DWQ-2510"},
    "ollama-qwen3-4b": {"url": "http://127.0.0.1:11434/v1", "model": "qwen3:4b-instruct"},
    "ollama-llama32-3b": {"url": "http://127.0.0.1:11434/v1", "model": "llama3.2:3b"},
}

TOPICS = ["unified memory", "KV cache", "quantization", "Metal kernels",
          "speculative decoding", "mixture of experts", "prefix caching",
          "thermal throttling", "tokenizers", "continuous batching"]


def filler(approx_tokens: int, seed: int = 1234) -> str:
    """Same generator shape as bench.py, so prompts are comparable across the two."""
    rng = random.Random(seed)
    out, chars, i = [], 0, 0
    while chars < approx_tokens * 4:
        i += 1
        a, b = rng.sample(TOPICS, 2)
        s = (f"Note {i}: measurement {rng.randint(100, 9999)} shows {a} interacting with {b} "
             f"in configuration {rng.choice('ABCDEFGH')}{rng.randint(1, 99)}, "
             f"variance {rng.random():.3f}. ")
        out.append(s)
        chars += len(s)
    return "".join(out)


def fm_count_tokens(text: str) -> int | None:
    """Apple's own tokenizer. The only authoritative count for the fm context limit."""
    try:
        p = subprocess.run(["fm", "count-tokens", text], capture_output=True, text=True,
                           timeout=120)
        m = re.search(r"\d+", re.sub(r"\x1b\[[0-9;]*m", "", p.stdout))
        return int(m.group()) if m else None
    except Exception:
        return None


def post(url: str, body: dict, timeout: int = 300):
    """Returns (http_status, parsed_json_or_text). Never raises on HTTP errors."""
    req = urllib.request.Request(url.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:
        return 0, f"{type(e).__name__}: {e}"


def stream(url: str, body: dict, timeout: int = 300) -> dict:
    """Streaming request. Captures SSE `event: error` frames, which a naive reader
    that only looks at content deltas will silently treat as an empty success."""
    body = {**body, "stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(url.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    t_first, content, usage, err, status = None, [], None, None, None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status = r.status
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("event:") and "error" in line:
                    err = "sse_error_event"
                    continue
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict) and obj.get("error"):
                    err = obj["error"].get("message", str(obj["error"]))
                    continue
                if obj.get("usage"):
                    usage = obj["usage"]
                for ch in obj.get("choices") or []:
                    c = (ch.get("delta") or {}).get("content") or ""
                    if c:
                        if t_first is None:
                            t_first = time.perf_counter()
                        content.append(c)
    except urllib.error.HTTPError as e:
        status = e.code
        err = e.read().decode("utf-8", "replace")[:300]
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
    t_end = time.perf_counter()
    text = "".join(content)
    ct = (usage or {}).get("completion_tokens")
    gen = (t_end - t_first) if t_first else None
    return {
        "status": status, "error": err, "text_head": text[:200], "chars": len(text),
        "ttft_s": (t_first - t0) if t_first else None,
        "e2e_s": t_end - t0,
        "prompt_tokens": (usage or {}).get("prompt_tokens"),
        "completion_tokens": ct,
        "decode_tps": ((ct - 1) / gen) if (ct and ct > 1 and gen and gen > 0.05) else None,
    }


def msg(text: str) -> list[dict]:
    return [{"role": "user", "content": text}]


# ------------------------------------------------------------------ ceiling
TERSE = "\n\nReply with exactly the two characters: OK"


def cmd_ceiling(args) -> dict:
    """Binary-search the largest prompt apple-fm accepts, measured in Apple's own tokens.

    Public sources disagree (4096 vs 8192) and Apple appears not to publish a figure,
    so this measures it rather than citing it.
    """
    be = BACKENDS["apple-fm"]
    lo, hi = 64, 16384           # lo known-good, hi known-bad (9024 failed in the main run)
    probes = []

    def try_n(approx: int) -> dict:
        body_text = filler(approx) + TERSE
        tok = fm_count_tokens(body_text)
        st, resp = post(be["url"], {"model": be["model"], "messages": msg(body_text),
                                    "stream": False, "temperature": 0})
        emsg = ""
        if isinstance(resp, dict) and resp.get("error"):
            emsg = resp["error"].get("message", "")
        ok = st == 200 and not emsg
        ptok = (resp.get("usage") or {}).get("prompt_tokens") if isinstance(resp, dict) else None
        rec = {"approx_tokens": approx, "fm_count_tokens": tok, "server_prompt_tokens": ptok,
               "http": st, "ok": ok, "error": emsg[:200]}
        probes.append(rec)
        print(f"  approx={approx:6} fm_tokens={tok} server_pt={ptok} http={st} "
              f"{'OK' if ok else 'FAIL: ' + emsg[:60]}")
        return rec

    print("== establishing bounds ==")
    assert try_n(lo)["ok"], "lower bound failed; fm serve may be down"
    if try_n(hi)["ok"]:
        print("  upper bound succeeded, no ceiling found below", hi)
        return {"probes": probes, "ceiling": None}

    print("== binary search ==")
    while hi - lo > 64:
        mid = (lo + hi) // 2
        if try_n(mid)["ok"]:
            lo = mid
        else:
            hi = mid

    ok_probes = [p for p in probes if p["ok"] and p["fm_count_tokens"]]
    bad_probes = [p for p in probes if not p["ok"] and p["fm_count_tokens"]]
    largest_ok = max((p["fm_count_tokens"] for p in ok_probes), default=None)
    smallest_bad = min((p["fm_count_tokens"] for p in bad_probes), default=None)
    print(f"\n  largest accepted : {largest_ok} fm-tokens")
    print(f"  smallest rejected: {smallest_bad} fm-tokens")
    return {"probes": probes, "largest_accepted_fm_tokens": largest_ok,
            "smallest_rejected_fm_tokens": smallest_bad}


# ------------------------------------------------------------------ max_tokens
def cmd_maxtokens(args) -> dict:
    """Does each backend honour max_tokens? apple-fm appeared not to in the main run."""
    # A bare "write a long essay" ask makes apple-fm decline outright ("I cannot write a
    # long detailed essay..."), which would hide whether max_tokens is honoured. Give it
    # source material, which it does expand on, so the cap is the only thing under test.
    long_prompt = (filler(512) + "\n\nUsing the notes above, write a long, detailed "
                   "technical report with numbered sections. Do not stop early.")
    rows = []
    for name, be in BACKENDS.items():
        for want in (16, 64, 256):
            r = stream(be["url"], {"model": be["model"],
                                   "messages": msg(f"[{uuid.uuid4().hex[:8]}] " + long_prompt),
                                   "max_tokens": want, "temperature": 0})
            got = r.get("completion_tokens")
            honoured = (got is not None and got <= want + 2)
            rows.append({"backend": name, "max_tokens": want, "completion_tokens": got,
                         "honoured": honoured, "error": r.get("error")})
            print(f"  {name:20} max_tokens={want:4} -> {got} "
                  f"{'ok' if honoured else 'IGNORED'}")
    return {"rows": rows}


# ------------------------------------------------------------------ curve
def cmd_curve(args) -> dict:
    """TTFT and decode rate vs prompt length, every backend, same prompts.

    apple-fm ignores max_tokens, so e2e is not comparable; we report TTFT (comparable)
    and decode tok/s (a rate, so comparable) and say so.
    """
    sizes = [128, 512, 2048, 4096]
    reps = args.reps
    rows = []
    for name, be in BACKENDS.items():
        for n in sizes:
            prompt = filler(n) + "\n\nSummarise the notes above in one paragraph."
            # one discarded warmup per (backend, size) to pay model-load cost once
            stream(be["url"], {"model": be["model"], "messages": msg(prompt),
                               "max_tokens": 128, "temperature": 0})
            for i in range(reps):
                r = stream(be["url"], {"model": be["model"],
                                       "messages": msg(f"[{uuid.uuid4().hex[:8]}] " + prompt),
                                       "max_tokens": 128, "temperature": 0})
                rows.append({"backend": name, "approx_prompt_tokens": n, "iter": i, **r})
                print(f"  {name:20} n={n:5} ttft={r['ttft_s'] and round(r['ttft_s'], 3)} "
                      f"dec={r['decode_tps'] and round(r['decode_tps'], 1)} "
                      f"ct={r['completion_tokens']} {r.get('error') or ''}")
                time.sleep(args.cooldown)
    return {"rows": rows, "sizes": sizes, "reps": reps}


# ------------------------------------------------------------------ schema
PERSON_SCHEMA = {
    "type": "object",
    "properties": {"name": {"type": "string"}, "age": {"type": "integer"},
                   "tags": {"type": "array", "items": {"type": "string"}}},
    "required": ["name", "age", "tags"],
}


def schema_ok(text: str) -> bool:
    t = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    try:
        o = json.loads(t)
    except Exception:
        return False
    return (isinstance(o, dict) and isinstance(o.get("name"), str)
            and isinstance(o.get("age"), int) and not isinstance(o.get("age"), bool)
            and isinstance(o.get("tags"), list)
            and all(isinstance(x, str) for x in o["tags"]))


def cmd_schema(args) -> dict:
    """Constrained JSON: free-form prompt vs server-enforced json_schema.

    Tests whether each backend's structured-output mode actually guarantees the shape,
    which is the property that matters for a router.
    """
    rf = {"type": "json_schema",
          "json_schema": {"name": "Person", "schema": PERSON_SCHEMA, "strict": True}}
    prompt = ("Invent one fictional person. Return a JSON object with keys "
              '"name" (string), "age" (integer), "tags" (array of strings).')
    rows = []
    for name, be in BACKENDS.items():
        for mode in ("freeform", "json_schema"):
            body = {"model": be["model"], "messages": msg(prompt),
                    "max_tokens": 200, "temperature": 0}
            if mode == "json_schema":
                body["response_format"] = rf
            oks, errs = [], []
            for i in range(args.reps):
                b = dict(body)
                b["messages"] = msg(f"[{uuid.uuid4().hex[:8]}] " + prompt)
                r = stream(be["url"], b)
                if r.get("error"):
                    errs.append(r["error"][:120])
                oks.append(schema_ok(r.get("text_head", "")))
                time.sleep(args.cooldown)
            rate = sum(oks) / len(oks) if oks else 0
            rows.append({"backend": name, "mode": mode, "valid_rate": rate,
                         "n": len(oks), "errors": errs[:2]})
            print(f"  {name:20} {mode:12} valid {rate:.0%} ({sum(oks)}/{len(oks)})"
                  + (f"  err={errs[0]}" if errs else ""))
    return {"rows": rows}


# ------------------------------------------------------------------ concurrency
def cmd_concurrency(args) -> dict:
    """Does the server overlap requests, or serialise them?

    A router fields many small calls at once; a server that serialises is a bottleneck
    no single-stream tok/s number reveals.
    """
    prompt = filler(256) + "\n\nSummarise in one sentence."
    rows = []
    for name, be in BACKENDS.items():
        # warm the model once per backend, else par=1 pays the load cost and the
        # scaling ratio is meaningless
        stream(be["url"], {"model": be["model"], "messages": msg(prompt),
                           "max_tokens": 64, "temperature": 0})
        for par in (1, 2, 4):
            def one(_):
                return stream(be["url"], {"model": be["model"],
                                          "messages": msg(f"[{uuid.uuid4().hex[:8]}] " + prompt),
                                          "max_tokens": 64, "temperature": 0})
            t0 = time.perf_counter()
            with ThreadPoolExecutor(max_workers=par) as ex:
                res = list(ex.map(one, range(par)))
            wall = time.perf_counter() - t0
            toks = sum((r.get("completion_tokens") or 0) for r in res)
            errs = [r["error"][:80] for r in res if r.get("error")]
            rows.append({"backend": name, "parallel": par, "wall_s": wall,
                         "total_completion_tokens": toks,
                         "aggregate_tps": toks / wall if wall else None,
                         "errors": errs[:2]})
            print(f"  {name:20} par={par} wall={wall:.2f}s tokens={toks} "
                  f"agg={toks / wall:.1f} tok/s" + (f"  ERR {errs[0]}" if errs else ""))
            time.sleep(args.cooldown)
    return {"rows": rows}


# ------------------------------------------------------------------ coldstart
def cmd_coldstart(args) -> dict:
    """First-token cost on a fresh request after an idle gap, vs immediately after.

    Apple's model is system-managed, so it may be paged out between uses in a way
    a resident oMLX/Ollama model is not.
    """
    rows = []
    short = "Say OK."
    for name, be in BACKENDS.items():
        warm = stream(be["url"], {"model": be["model"], "messages": msg(short),
                                  "max_tokens": 8, "temperature": 0})
        time.sleep(args.idle)
        cold = stream(be["url"], {"model": be["model"], "messages": msg(short),
                                  "max_tokens": 8, "temperature": 0})
        back = stream(be["url"], {"model": be["model"], "messages": msg(short),
                                  "max_tokens": 8, "temperature": 0})
        rows.append({"backend": name, "idle_s": args.idle,
                     "warm_ttft_s": warm.get("ttft_s"),
                     "after_idle_ttft_s": cold.get("ttft_s"),
                     "next_ttft_s": back.get("ttft_s")})
        print(f"  {name:20} warm={warm.get('ttft_s')} after_idle={cold.get('ttft_s')} "
              f"next={back.get('ttft_s')}")
    return {"rows": rows}


CMDS = {"ceiling": cmd_ceiling, "maxtokens": cmd_maxtokens, "curve": cmd_curve,
        "schema": cmd_schema, "concurrency": cmd_concurrency, "coldstart": cmd_coldstart}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=list(CMDS))
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--cooldown", type=float, default=2.0)
    ap.add_argument("--idle", type=float, default=90.0, help="coldstart: idle gap seconds")
    args = ap.parse_args()

    OUT.mkdir(exist_ok=True)
    print(f"== {args.cmd} ==")
    t0 = time.time()
    result = CMDS[args.cmd](args)
    result["_meta"] = {
        "cmd": args.cmd, "timestamp": datetime.now().isoformat(timespec="seconds"),
        "elapsed_s": round(time.time() - t0, 1),
        "os": subprocess.run(["sw_vers", "-productVersion"], capture_output=True,
                             text=True).stdout.strip(),
        "build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True,
                                text=True).stdout.strip(),
        "backends": BACKENDS,
    }
    path = OUT / f"{args.cmd}.json"
    path.write_text(json.dumps(result, indent=2))
    print(f"\n-> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
