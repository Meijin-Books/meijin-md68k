# meijin-md68k

書籍『**Meijin 68000アセンブリ ＆ MeijinOS68k**』（Meijinシリーズ）のサンプルコードです。
メガドライブ（Mega Drive / Genesis）の68000アセンブリを学び、その同じ命令だけで
小さなマルチタスクOSを一つ組み上げるまでの、全ソースコードを収録しています。

本書は「二冊分の旅を一冊にまとめた」二部構成です。このリポジトリも、それに合わせて
二つのフォルダに分かれています。

| フォルダ | 対応 | 内容 |
|---|---|---|
| [`part1-asm/`](part1-asm/) | 第一部　アセンブリ編（第0〜12章） | 画面表示・スプライト操作までの68000アセンブリ |
| [`part2-os/`](part2-os/)   | 第二部　OS実装編（第13〜28章） | MeijinOS68k の全実装（コンテキストスイッチ〜メモリ管理） |

心臓部（コンテキストスイッチ）は **13命令**。1ページに印刷して、全行を説明できます（第16章）。

## 必要なもの

- [vasm](http://sun.hasenbraten.de/vasm/)（m68k / Motorola syntax）── `vasmm68k_mot`
- [BlastEm](https://www.retrodev.com/blastem/) などのメガドライブ・エミュレータ

どちらも無料です。動作確認環境：vasm 2.0x、BlastEm 0.6.2、Windows 11。

## 入手

```sh
git clone https://github.com/Meijin-Books/meijin-md68k.git
```

Gitを使わない場合は、ページ上部の緑色の **Code** ボタン → **Download ZIP** から一式を入手できます。

## ライセンス

MIT License（[LICENSE](LICENSE)）。改変・商用利用ともに自由です。
学んだものを使って何かを作っていただけたら、それが一番うれしい報酬です。

- X: [@Meijin_Books](https://x.com/Meijin_Books)
