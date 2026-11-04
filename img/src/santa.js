// santa-before と santa-after の中身。2 枚の枠組み（位置と大きさ）は同じで、body の data-mode で描き分ける。
//   before: 暗号化しても、使用中のデータ（メモリの上で復号した希望）は、運営者が root の権限で読める（記事「そもそも使用中のデータの保護とは？」）
//   after : 同じ枠に Enclave と KMS を加える。運営者は Enclave のメモリを読めない。KMS は復号の結果を Enclave にだけ渡す。
//           Enclave は結果を参加者の公開鍵で暗号化して返す（記事「AWS Nitro Enclavesとは？」の冒頭の 3 か所の変化）
// 座標は DESIGN.md §6-2 による（#fig 800 × 600、左上が原点）。
// DESIGN との違い: KMS のアイコンと矢印 3 は、DESIGN の x 656 ではなく x 712 に置く。
//   x 656 では、矢印 3 が Enclave の枠の見出し（アイコンと「Enclave」、x 560〜670）に重なるため。KMS の名前はアイコンの左に置く。
// 根拠: 概念図。ne-001・ne-002（Enclave は親インスタンスの root からも隔離された VM）、
//   ne-081（KMS は Recipient を付けた Decrypt の結果を、文書の公開鍵で暗号化して CiphertextForRecipient で返す）、
//   アプリの設計（hands-on/enclave/app.py が結果を参加者の公開鍵で暗号化する。README 手順 9）。
//   TLS で暗号化するのは転送中のデータ（記事の定義）。
// before では KMS を描かないため、上の 112px（KMS の領域）を切り取る。#fig の高さを 488px にし、
//   中身をすべて 112px 上へずらす（#fig の直下の要素の margin-top を -112px にする）。部品どうしの位置と大きさは 2 枚で同じ。
//   after だけが、同じ配置の上に KMS の領域を加える。
// アイコン: npm パッケージ aws-icons（Users, User, AmazonEC2Instance, AWSNitroEnclaves, AWSKeyManagementService）
(() => {
  const AFTER = document.body.dataset.mode === 'after';
  const fig = document.getElementById('fig');
  fig.insertAdjacentHTML('beforeend', `
  <style>
    #fig { height: ${AFTER ? 600 : 488}px; }
    ${AFTER ? '' : '#fig > * { margin-top: -112px; }'}
    .mem { position: absolute; border: 2px solid var(--ink); background: #fff; padding: 8px 10px; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }
    .mem .tg { margin-bottom: 4px; }
    .mem b { font-size: 17px; font-weight: 900; line-height: 1.35; }
    .mem.hot { border: 3px solid var(--hot); }
    .who { position: absolute; text-align: center; white-space: nowrap; }
    .who b { display: block; font-size: 18px; font-weight: 900; line-height: 1.3; }
    .who span { display: block; font-size: 16px; font-weight: 500; color: #4a4843; line-height: 1.4; }
  </style>

  <!-- 参加者（灰色の点線の枠）。アイコンと名前は枠の中で上下・左右の中央 -->
  <div class="lane" style="left:24px;top:136px;width:180px;height:440px"></div>
  <img class="ic" src="../icons/Users.svg" style="left:86px;top:300px;width:56px;height:56px">
  <div class="who" style="left:24px;width:180px;top:362px"><b>参加者</b><span>希望を書く</span></div>

  <!-- 運営者のサーバー -->
  <div class="grp" style="left:344px;top:136px;width:432px;height:440px">
    <div class="gl"><img src="../icons/AmazonEC2Instance.svg"><span class="ja">運営者のサーバー</span></div>
  </div>
  <div class="mem" style="left:368px;top:208px;width:160px;height:80px"><span class="tg line">保存中</span><b>暗号化した希望</b></div>

  ${AFTER ? `
  <div class="grp enc" style="left:560px;top:208px;width:192px;height:180px">
    <div class="gl"><img src="../icons/AWSNitroEnclaves.svg"><span class="ja">Enclave</span></div>
  </div>` : ''}
  <div class="mem${AFTER ? '' : ' hot'}" style="left:584px;top:280px;width:144px;height:84px"><span class="tg${AFTER ? ' line' : ' hot'}">使用中</span><b>復号した希望<br>組み合わせ</b></div>

  <!-- 運営者 -->
  <img class="ic" src="../icons/User.svg" style="left:632px;top:452px;width:48px;height:48px">
  <div class="who" style="left:581px;width:150px;top:506px"><b>運営者</b><span>root の権限</span></div>

  <!-- 矢印 1: 希望を送る。転送中のデータは TLS で暗号化する -->
  <div class="lb" style="left:234px;top:214px">希望を送る</div>
  <span class="tg line abs" style="left:242px;top:258px">転送中</span>
  <span class="tg line abs" style="left:220px;top:292px">TLS で暗号化</span>

  ${AFTER ? `
  <!-- KMS: 復号の結果を Enclave にだけ渡す -->
  <img class="ic" src="../icons/AWSKeyManagementService.svg" style="left:688px;top:24px;width:48px;height:48px">
  <div class="nm r" style="right:124px;top:34px">KMS</div>
  <div class="lb hot r" style="right:100px;top:93px">復号の結果を Enclave にだけ渡す</div>
  <!-- 矢印 4: Enclave から参加者へ -->
  <div class="lb hot" style="left:384px;top:352px">参加者の公開鍵で<br>暗号化した結果</div>
  <div class="lb grey" style="left:668px;top:415px">読めない</div>
  ` : `
  <div class="lb hot" style="left:668px;top:404px">読める</div>
  `}
  `);

  window.addEventListener('load', async () => {
    await document.fonts.ready;
    poly([[204, 248], [364, 248]]);
    if (AFTER) {
      poly([[656, 448], [656, 400]], { grey: true });
      poly([[712, 76], [712, 204]], { hot: true });
      poly([[557, 340], [208, 340]], { hot: true });
    } else {
      poly([[656, 448], [656, 368]], { hot: true });
    }
    document.body.dataset.ready = '1';
  });
})();
