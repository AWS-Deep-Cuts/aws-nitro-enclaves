# 図の元データ

`img/*.png` の元になる HTML です。ハンズオンの実行には不要です。

- 図は [Kenta-Matsuda/slide-template](https://github.com/Kenta-Matsuda/slide-template) と同じ仕組み（HTML ＋ AWS 公式アイコン ＋ `wires.js` の矢印）で描いています。`diagram.css` と `wires.js` はそのテンプレートのものです。`deepcuts.css` は記事の本文幅に合わせて足した部品です。
- アイコンは npm パッケージ `aws-icons` の SVG を `img/icons/` にコピーしています。
- `ne.css` はこのリポジトリの図で共通の部品（枠・箱・線の説明）、`lines.js` は座標を指定して水平と垂直の線だけで矢印を引く関数 `poly()` です。`santa.js` は `santa-before` と `santa-after` の共通の中身で、`body` の `data-mode` で描き分けます。

書き出し方（Chrome か Chromium が必要です）:

```bash
cd img/src
npm install
node render-diagrams.cjs "<Chrome の実行ファイルのパス>"            # すべての図を書き出す
node render-diagrams.cjs "<Chrome の実行ファイルのパス>" architecture  # 1 つだけ書き出す
```
