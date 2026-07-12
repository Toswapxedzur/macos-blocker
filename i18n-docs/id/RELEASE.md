# Panduan rilis Mac Vault

Panduan ini mengikuti skrip build yang telah diperiksa. Sengaja tidak memuat identitas penandatanganan pribadi, profil notaris, kata sandi, atau data akun.

## Sebelum rilis

1. Jalankan `swift test` dari root repositori.
2. Tetapkan versi rilis dan nomor build dalam konfigurasi proyek/build yang dikontrol.
3. Tinjau manual bahasa Inggris, manual lokal, dan audit terjemahan editor.
4. Verifikasi kebijakan cabang rilis, tag, dan pencapaian sebelum menerbitkan artefak.

## Saluran DMG situs web

Skripnya ada di `scripts/release/`. Defaultnya dapat diganti dengan variabel lingkungan, termasuk `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, dan `BUILD_NUMBER`.

Jalankan alur lengkap hanya pada mesin penandatanganan yang dikonfigurasi:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

Pipeline menyusun skrip pembangunan, penandatanganan, DMG, notarisasi, dan verifikasi yang ada. Perlakukan keluarannya sebagai kandidat rilis hingga langkah verifikasi berhasil.

## Target distribusi Xcode

Hasilkan proyek Xcode dari `XcodeProject/project.yml`, konfigurasikan tim penandatanganan dan kemampuan yang sesuai di lingkungan yang disetujui, lalu arsipkan target yang relevan. Jangan melakukan kredensial yang dihasilkan, file provisi, atau profil notaris.

## Setelah rilis

1. Buat tag versi yang tidak dapat diubah dan cabang rilis permanen sesuai dengan kebijakan manajemen rilis.
2. Publikasikan artefak rilis dan checksum.
3. Perbarui registri rilis publik hanya setelah URL artefak bersifat final.
4. Simpan catatan rilis dalam bahasa Inggris kecuali jika disediakan catatan rilis lokal yang telah ditinjau.
