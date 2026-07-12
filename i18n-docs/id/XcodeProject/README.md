# Proyek Mac Vault Xcode

`project.yml` adalah spesifikasi XcodeGen yang dicentang untuk target macOS dan iOS yang menggunakan paket Swift bersama.

## Hasilkan proyek

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

Regenerasi setelah mengubah `project.yml`, target, hak, atau keanggotaan sumber. Jangan gunakan file proyek yang dihasilkan sebagai konfigurasi kanonik.

## Keluarga sasaran saat ini

- `AdamanciaVaultMac` adalah target aplikasi macOS yang didukung oleh `MacBlockerAppFeature`.
- `macosBlocker` adalah target aplikasi iOS.
- Proyek iOS mencakup Aktivitas Perangkat, Konfigurasi Perisai, dan ekstensi Tindakan Perisai.

Pengidentifikasi saat ini, target penerapan, bidang versi, dan kemampuan ditentukan dalam `project.yml` dan file hak yang direferensikan. Tinjau mereka di lingkungan penandatanganan sebelum distribusi.

## Penandatanganan dan kemampuan

Gunakan pengidentifikasi tim dan bundel milik akun distribusi. Konfirmasikan kemampuan yang dibutuhkan oleh target yang Anda bangun. Jangan pernah menambahkan rahasia penandatanganan, profil penyediaan, atau kredensial akun ke repositori ini.

## Tes dulu

Jalankan pengujian paket bersama sebelum membuat arsip:

```bash
cd ..
swift test
```
