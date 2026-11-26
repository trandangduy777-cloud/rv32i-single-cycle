#!/usr/bin/env python3
"""Kiem nhip commit cua repo (chong merge commit, chong vuot 12 commit / ngay, chong commit chẻ vụn) va author.

Quy tac (README, muc Quy trinh commit):
  (a) moi commit tren main co dung 1 cha (squash merge, khong merge commit);
  (b) moi ngay (gio Viet Nam, theo ngay author) toi da 12 commit tren main, tinh moi commit main chua (ca commit tu nhanh
      da merge), vi 5 chat cung commit vao mot repo;
  (c) canh bao dau hieu chẻ vụn: commit trong vong 2 gio sau commit truoc ma < 20 dong thay doi, hoac chi doi
      README / tai lieu / YAML (phan va va README phai nam trong commit cua chinh tinh nang);
  (d) --author: author email cua moi commit duoc kiem phai la email cua chu repo (khong phai noreply@anthropic.com).

Dung:
  python3 tools/check_commits.py --history            # bao cao toan bo lich su main (chi bao, thoat 0)
  python3 tools/check_commits.py --range A..B         # kiem cac commit moi trong A..B (job push tren main): (a)(b) loi, (c) canh bao
  python3 tools/check_commits.py --pr [--base REF]    # truoc khi squash: commit hom nay tren main + 1 phai <= 12
  python3 tools/check_commits.py --author --range A..B   # (d) cho cac commit trong A..B
Them --strict de (c) cung thanh loi.
"""
import argparse, datetime as dt, subprocess, sys

VN = dt.timezone(dt.timedelta(hours=7))
MAX_PER_DAY = 12
SMALL_LINES = 20
WINDOW_H = 2
OWNER_EMAILS = {"trandangduy777@gmail.com",
                "312960831+trandangduy777-cloud@users.noreply.github.com"}  # GitHub co the dung noreply cho squash merge
DOC_ONLY = (".md", ".yml", ".yaml", ".txt")


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def commits(rev):
    """List dict cho moi commit trong rev (cu -> moi theo thu tu topo)."""
    out = git("log", "--reverse", "--format=%H%x1f%P%x1f%at%x1f%ae%x1f%s", rev)
    res = []
    for line in out.splitlines():
        h, p, at, ae, s = line.split("\x1f")
        res.append(dict(h=h, parents=p.split(), t=int(at), email=ae, subj=s,
                        day=dt.datetime.fromtimestamp(int(at), VN).strftime("%Y-%m-%d")))
    return res


def stat(h, nparents):
    """(so dong them + xoa, list file) so voi cha dau tien (merge commit: so voi cha dau)."""
    if nparents == 0:
        return 0, []
    out = git("diff", "--numstat", h + "^1", h)
    lines, files = 0, []
    for l in out.splitlines():
        a, d, f = l.split("\t", 2)
        lines += (int(a) if a != "-" else 0) + (int(d) if d != "-" else 0)
        files.append(f)
    return lines, files


def short(c):
    return f"{c['h'][:7]} ({dt.datetime.fromtimestamp(c['t'], VN):%d/%m %H:%M}) {c['subj'][:70]}"


def analyse(all_main, check):
    """all_main: moi commit tren main (de dem ngay va tim commit truoc); check: tap hash can kiem."""
    errs, warns = [], []
    per_day = {}
    for c in all_main:
        per_day.setdefault(c["day"], []).append(c)
    ordered = sorted(all_main, key=lambda c: c["t"])
    prev = {c["h"]: (ordered[i - 1] if i else None) for i, c in enumerate(ordered)}
    days = set()
    for c in all_main:
        if c["h"] not in check:
            continue
        days.add(c["day"])
        if len(c["parents"]) != 1 and not (len(c["parents"]) == 0 and c is ordered[0]):   # commit goc cua repo thi bo qua
            errs.append(f"(a) merge commit / khong co cha: {short(c)} co {len(c['parents'])} cha")
        p = prev[c["h"]]
        if p is not None and len(c["parents"]) == 1 and c["t"] - p["t"] <= WINDOW_H * 3600:
            n, files = stat(c["h"], 1)
            doc = files and all(f.endswith(DOC_ONLY) for f in files)
            if n < SMALL_LINES or doc:
                why = f"{n} dong" if n < SMALL_LINES else "chi doi " + ", ".join(files)
                warns.append(f"(c) dau hieu chẻ vụn: {short(c)}: {why}, {(c['t'] - p['t']) // 60} phut sau {p['h'][:7]}")
    for d in sorted(days):
        if len(per_day[d]) > MAX_PER_DAY:
            errs.append(f"(b) ngay {d} (gio VN) co {len(per_day[d])} commit tren main (toi da {MAX_PER_DAY})")
    return errs, warns


def resolve_range(r):
    a, b = r.split("..")
    if not a or set(a) == {"0"} or subprocess.run(["git", "cat-file", "-e", a + "^{commit}"],
                                                    capture_output=True).returncode:
        a = ""   # lan push dau cua nhanh (before = 000...) hoac before khong con (force-push): chi kiem HEAD
    return a, b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--history", action="store_true")
    ap.add_argument("--range", default="")
    ap.add_argument("--pr", action="store_true")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--author", action="store_true")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--today", default="", help="YYYY-MM-DD (thu nghiem --pr)")
    a = ap.parse_args()

    if a.author:
        lo, hi = resolve_range(a.range or a.base + "..HEAD")
        cs = commits(f"{lo}..{hi}") if lo else commits(hi)[-1:]
        bad = [c for c in cs if c["email"] not in OWNER_EMAILS]
        for c in bad:
            print(f"::error::[check_commits] (d) author {c['email']} khong phai chu repo: {short(c)}")
        print(f"[check_commits] author: {len(cs)} commit, {len(bad)} sai (dat git config user.email truoc khi commit)")
        sys.exit(1 if bad else 0)

    if a.pr:
        today = a.today or dt.datetime.now(VN).strftime("%Y-%m-%d")
        n = sum(1 for c in commits(a.base) if c["day"] == today)
        ok = n + 1 <= MAX_PER_DAY
        print(f"[check_commits] hom nay {today} (gio VN) main co {n} commit; squash them 1 -> {n + 1}/{MAX_PER_DAY}"
              + ("" if ok else ": HET SUAT, cho sang ngay (khong sua ngay commit)"))
        sys.exit(0 if ok else 1)

    main_ref = "origin/main" if subprocess.run(["git", "rev-parse", "-q", "--verify", "origin/main"],
                                               capture_output=True).returncode == 0 else "HEAD"
    if a.history:
        allc = commits(main_ref)
        check = {c["h"] for c in allc}
    else:
        lo, hi = resolve_range(a.range or "HEAD~1..HEAD")
        allc = commits(hi)
        check = {c["h"] for c in (commits(f"{lo}..{hi}") if lo else allc[-1:])}
    errs, warns = analyse(allc, check)
    for e in errs:
        print(("::warning::" if a.history else "::error::") + "[check_commits] " + e)
    for w in warns:
        print(("::error::" if a.strict and not a.history else "::warning::") + "[check_commits] " + w)
    print(f"[check_commits] {len(check)} commit duoc kiem: {len(errs)} loi (a)/(b), {len(warns)} canh bao (c)"
          + (" [chi bao cao lich su]" if a.history else ""))
    if a.history:
        sys.exit(0)
    sys.exit(1 if errs or (a.strict and warns) else 0)


if __name__ == "__main__":
    main()
