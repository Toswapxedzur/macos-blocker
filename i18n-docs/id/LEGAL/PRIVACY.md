# Kebijakan Privasi Adamancia Vault

Terakhir diperbarui: 7 Juli 2026

Adamancia Vault adalah aplikasi fokus dan pemblokiran. Kebijakan ini menjelaskan rilis aplikasi macOS.

## Ringkasan

Adamancia Vault dirancang untuk menjaga aturan pemblokiran dan status penggunaan tetap lokal pada Mac Anda secara default. Aplikasi ini tidak menjual data pribadi, tidak menampilkan iklan, dan tidak membagikan data pribadi dengan broker data.

## Data Disimpan Secara Lokal

App mungkin menyimpan data lokal berikut di Mac Anda:

- Memblokir grup, jadwal, pengatur waktu, keadaan beku/tunda, dan pengaturan aplikasi.
- Penyimpanan editor web lokal dicerminkan dari antarmuka web yang dibundel.
- Status jembatan/tautan lokal saat Anda menghubungkan aplikasi macOS ke ekstensi browser.
- File kebijakan penegakan aplikasi yang digunakan oleh mesin pemblokiran macOS.
- Data kontainer Grup Aplikasi ketika build App Store atau build ekstensi menggunakan Grup Aplikasi.

Jalur lokal yang diketahui didokumentasikan di `RELEASE.md` dan dalam skrip uninstaller.

## Penggunaan Jaringan

Aplikasi dapat membuka pendengar jaringan lokal untuk jembatan aplikasi webnya sehingga ekstensi browser dapat terhubung ke aplikasi Mac. Aplikasi juga dapat membuat permintaan jaringan jika fitur yang dibundel perlu berkomunikasi dengan layanan Adamancia, misalnya akun opsional atau fitur terkait sinkronisasi.

## Analisis dan Iklan

Aplikasi macOS tidak menyertakan SDK periklanan pihak ketiga. Ini tidak boleh mengirimkan analitik kecuali fitur secara eksplisit menyatakan bahwa ia menggunakan layanan online.

## Akun Opsional dan Sinkronisasi

Jika fitur akun atau sinkronisasi diaktifkan dalam rilis, fitur tersebut mungkin mengirimkan data minimum yang diperlukan untuk menyediakan fitur tersebut, seperti identitas akun dan payload sinkronisasi. Pengunduhan dan pemblokiran lokal tidak memerlukan akun.

## Izin

Bergantung pada saluran dan fitur yang diaktifkan, Adamancia Vault mungkin meminta izin macOS seperti Aksesibilitas, akses jaringan, pendaftaran item masuk, atau akses Grup Aplikasi. Izin ini digunakan untuk menyediakan fitur pemblokiran, peluncuran aplikasi, jembatan, dan persistensi.

## Menghapus instalasi

DMG tersebut mencakup `uninstall.command`. Ia meminta konfirmasi, keluar dari aplikasi jika berjalan, membatalkan pendaftaran item login aplikasi bila memungkinkan, menghapus `/Applications/AdamanciaVault.app`, dan secara opsional hanya menghapus file yang diketahui yang dibuat oleh aplikasi ini.

## Kontak

Untuk pertanyaan privasi, buka terbitan di repositori GitHub publik atau gunakan saluran kontak yang dipublikasikan di situs web Adamancia Vault.
