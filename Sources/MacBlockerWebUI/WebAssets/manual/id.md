# Referensi fungsional aplikasi desktop Vault

## Tujuan dan batasan

Ini adalah referensi resmi untuk antarmuka aplikasi desktop Vault. Ini sengaja dipisahkan dari manual ekstensi browser Vault.

Aplikasi desktop mengelola **aplikasi asli dan jendela aplikasi**. Ekstensi browser mengelola situs web, tab browser, dan feed platform web yang didukung. Mereka berbagi ide yang sama—grup, jadwal, pengatur waktu, pembekuan, penundaan, Aturan khusus, dan jembatan opsional—tetapi mereka tidak memiliki permukaan penegakan yang sama.

Gunakan dokumen ini untuk mengonfigurasi, mengaudit, mereproduksi, atau memelihara perilaku aplikasi desktop. Kode ini kanonik jika implementasi dan manual ini berbeda.

## 1. Apa yang bisa dan tidak bisa dikontrol oleh aplikasi desktop

Vault mengevaluasi kebijakan fokus untuk aplikasi asli yang dipilih. Ketika kemampuan penegakan aslinya tersedia, ia dapat menerapkan rencana saat ini untuk mencocokkan target aplikasi dan melaporkan hasil perlindungan/status ke UI host.

Itu bisa:

- membuat, mengaktifkan, menonaktifkan, menyusun ulang, mengimpor, mengekspor, membekukan, menunda, dan menghapus grup;
- menargetkan aplikasi asli yang dipilih melalui pemilih aplikasi;
- menerapkan blok langsung, tunjangan berwaktu, atau pengatur waktu penghitungan saja;
- membatasi grup normal pada hari kerja dan jendela waktu setempat;
- menjalankan aturan kebijakan JavaScript Khusus untuk peristiwa siklus hidup aplikasi;
- menampilkan informasi status/panel asli yang dibuat aturan melalui host;
- mengelola folder lokal opsional untuk permintaan file aturan khusus yang didukung;
- bergabung dengan grup yang kompatibel dan tertaut secara eksplisit melalui jembatan Vault lokal.

Itu tidak bisa:

- bertindak sebagai ekstensi browser, memeriksa DOM situs web, atau memanipulasi kartu umpan browser;
- jaminan bahwa sistem operasi akan memungkinkan setiap aplikasi, proses, jendela, atau layanan sistem dikendalikan;
- mengubah pemilihan aplikasi menjadi administrasi jarak jauh, pengawasan perangkat, atau firewall;
- membuat pembantu khusus khusus browser seperti DOM, navigasi, pengalihan, atau kontrol tab berfungsi di runtime asli;
- menyinkronkan setiap grup secara otomatis hanya karena jembatan lokal sedang berjalan.

## 2. Kosakata

| Istilah | Arti |
| --- | --- |
| Grup | Objek kebijakan fokus bernama. Nama grup harus unik dalam titik akhir Vault saat ini. |
| Sasaran | Identitas aplikasi asli yang dipilih untuk grup. |
| Grup aplikasi bawaan | Grup normal yang targetnya adalah aplikasi asli dari pemilih aplikasi. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Cocokkan | Aplikasi latar depan/yang berjalan saat ini cocok dengan target grup yang diaktifkan dan aktif atau kondisi Aturan khusus. |
| Aktif | Diaktifkan, dalam jadwal normal, dan tidak ditunda secara aktif. |
| Rencana penegakan | Keputusan izinkan/perisai/status yang dihasilkan oleh host asli setelah mengevaluasi grup yang berlaku. |
| Bekukan | Perlindungan terhadap modifikasi biasa suatu grup. |
| Tunda | Pengecualian sementara dari kebijakan grup normal. |

## 3. Identitas target dan pemilih aplikasi

Pilih aplikasi melalui pemilih **** di grup Aplikasi default. Vault menyimpan identitas yang dinormalisasi serta nama tampilan.

| Tuan rumah | Identitas target yang digunakan untuk pencocokan |
| --- | --- |
| macOS | Pengidentifikasi bundel aplikasi jika tersedia. |
| jendela | Jalur eksekusi atau nama proses yang dinormalisasi disediakan oleh pemilih aplikasi. |

Nama tampilan adalah untuk editor. Nilai yang dinormalisasi adalah identitas yang digunakan oleh lapisan penegakan asli. Mengganti nama aplikasi di UI tidak mengubah identitas. Target juga dapat membawa tag untuk penggunaan kebijakan aturan khusus.

Jangan masukkan URL situs web di bidang target aplikasi dan mengharapkan penerapan aplikasi asli. Gunakan grup Situs ekstensi untuk memblokir situs web.

## 4. Siklus hidup dan prioritas grup

Grup baru diaktifkan secara default. Daftar grup mendukung pemilihan, mengaktifkan/menonaktifkan, pengurutan seret, Tambah, Hapus, impor, ekspor, dan penghapusan. Grup yang dipilih akan terbuka di editor.

Pengeditan bidang normal disimpan melalui kebijakan penyimpanan otomatis editor. Grup yang dibekukan menonaktifkan kontrol pengeditan biasa. Sumber Kustom berbeda: menyimpan teks tidak membuatnya aktif; **Run** adalah operasi yang memuat sumber saat ini ke dalam runtime kebijakan.

Beberapa kelompok dapat mencocokkan aplikasi yang sama. Vault mengevaluasi kebijakan grup dalam urutan tersimpan dan membuat rencana penerapan asli. Jaga agar tumpang tindih tetap disengaja, terutama ketika kelompok menggunakan kebijakan waktu yang berbeda atau aturan khusus mengeluarkan keputusan yang diperbolehkan/melindungi. Susun ulang kelompok-kelompok tersebut agar prioritas yang diinginkan menjadi jelas; jangan mengandalkan konfigurasi konflik yang diselesaikan dengan cara tertentu yang mudah digunakan.

## 5. Grup aplikasi normal

### 5.1 Status grup

| Bidang | Kontrak fungsional |
| --- | --- |
| Nama | Tidak kosong, terpotong, dan tidak peka huruf besar/kecil dalam titik akhir ini. |
| Diaktifkan | Kelompok penyandang disabilitas tetap dipertahankan tetapi tidak mengambil bagian dalam penegakan hukum secara normal. |
| Sasaran | Satu atau lebih identitas aplikasi dipilih dari alat pilih. |
| Perilaku | Blokir segera, blok setelah uang saku, atau pengatur waktu/penghitungan. |
| Jadwal | Hari kerja yang dipilih dan jendela waktu lokal opsional. |
| Bekukan | Tidak ada, Beku, Beku ketat, atau Beku orang tua. |
| Tunda | Kebijakan pengecualian sementara per grup. |
| Pesan cadangan/status | Pesan yang dapat ditampilkan oleh host asli ketika ia menerapkan respons perisai/status. |

Grup Default yang kosong tidak memiliki target aplikasi yang dipilih dan oleh karena itu tidak cocok dengan aplikasi yang sudah ada.

### 5.2 Memblokir perilaku

| Perilaku | Hasil |
| --- | --- |
| Blokir segera | Target aktif yang cocok menghasilkan keputusan blok/perisai asli secara langsung. |
| Blokir setelah beberapa menit | Penggunaan yang sesuai diperoleh dari tunjangan kelompok. Ketika tunjangan habis, grup menghasilkan keputusan blok/perisai asli hingga periode penggunaannya direset atau keadaan lain membuat grup tidak aktif. |
| Timer (hitungan, tanpa blok) | Penggunaan yang cocok diukur dan dapat ditampilkan, tetapi pengatur waktu itu sendiri tidak pernah menghasilkan blok. |

Grup baru menggunakan waktu luang 15 menit dan interval pengaturan ulang 24 jam kecuali diubah. Penggunaan berwaktu adalah milik grup, jadi semua target yang cocok memiliki kebijakan grup yang sama. Respons yang tepat terhadap suatu blok diterapkan oleh host asli dan dibatasi oleh izin sistem operasi dan mekanisme penegakan yang didukung.

### 5.3 Jadwal

Jadwal berlaku untuk grup normal. Grup Kustom membuat keputusan waktunya sendiri dalam JavaScript.

Pilih kombinasi apa pun dari Senin hingga Minggu. Setiap jendela waktu adalah satu baris dalam waktu lokal:

```text
0900-1200
1330-1730
```

Format sebenarnya yang diterima adalah HHMM-HHMM. Jam harus antara 00 sampai 23, menit 00 sampai 59, dan jam mulai harus lebih awal dari jam berakhir pada hari yang sama. Sebuah jendela menyertakan bagian awal dan tidak termasuk bagian akhir. Jendela lintas tengah malam tidak diterima. Jendela kosong berarti seluruh hari yang dipilih.

Grup normal hanya aktif jika:

1. diaktifkan;
2. hari kerja saat ini dipilih;
3. waktu setempat ada di dalam jendela yang dikonfigurasi, atau grup tidak memiliki jendela;
4. tidak dalam keadaan tunda aktif.

### 5.4 Tunda

Tunda untuk sementara menghapus grup normal dari penegakan aktif. Fase-fasenya adalah:

| Fase | Hasil |
| --- | --- |
| Tertunda | Permintaan ada namun penundaan aktivasi belum berlalu; grup tersebut tetap aktif. |
| Aktif | Grup untuk sementara tidak aktif selama durasi tunda. |
| Masa Tenang | Tunda telah berakhir dan grup aktif kembali, namun tunda baru belum tersedia. |

| Pengaturan | Aturan |
| --- | --- |
| Izinkan tunda | Jika tidak aktif, grup tidak dapat ditunda secara normal. |
| Durasi tunda | Jumlah menit positif. Default untuk grup baru adalah 30 menit. |
| Penundaan aktivasi | Nol menit atau lebih sebelum tunda menjadi aktif. |
| Masa Tenang | Nol hingga lima menit setelah tunda aktif berakhir. |
| Konfirmasi | Jumlah interaksi konfirmasi yang diperlukan adalah bilangan bulat non-negatif. |

Tunda aktif adalah pengecualian kebijakan sementara, bukan penghapusan atau pencairan. Konfigurasi grup tetap utuh.

### 5.5 Bekukan

Pembekuan adalah penghalang modifikasi yang disengaja.

| Modus | Kontrak |
| --- | --- |
| Beku | Pengeditan biasa dan perubahan status biasa tetap terkunci hingga aliran konfirmasi pencairan pembekuan produk berhasil. |
| Beku ketat | Grup tidak dapat dicairkan sebelum durasi pembekuan ketatnya berakhir. Durasinya positif dan dibatasi hingga 72 jam. |
| Orang tua dibekukan | Manajemen kata sandi wali diperlukan untuk tindakan membekukan/mencairkan. |

Memilih mode di editor tidak membekukan grup dengan sendirinya; gunakan tindakan bekukan untuk menerapkannya. Grup yang terhubung dengan jembatan juga dapat mengunci kontrol pembekuan terkoordinasi saat anggota yang diperlukan sedang offline.

## 6. Penegakan asli dan kontrol perangkat

Editor dapat menyimpan grup secara akurat meskipun sistem operasi belum memberikan kemampuan untuk menerapkannya. Selalu periksa **Pengaturan → Kontrol Perangkat** dan status asli aktif setelah mengubah izin.

Host asli memutuskan tindakan apa yang mungkin dilakukan untuk sistem operasi, aplikasi, jendela, dan status izin saat ini. Aturan dapat dikonfigurasi dengan benar namun tidak memiliki efek yang terlihat jika:

- Kontrol Perangkat tidak diberikan atau telah dicabut;
- grup dinonaktifkan, dijadwalkan, atau ditunda secara aktif;
- proses terfokus tidak sesuai dengan target normalisasi yang dipilih;
- sistem operasi menolak tindakan untuk target tersebut;
- ketergantungan jembatan sedang offline untuk tindakan yang memerlukan keadaan terkoordinasi.

Jangan menganggap keberhasilan penyelamatan sebagai bukti bahwa penegakan aktif tersedia. Uji target yang dipilih saat grup aktif dan periksa status host.

## 7. Grup khusus dan aturan kebijakan asli

Grup khusus dijalankan pada runtime kebijakan JavaScript asli. Itu bukan aturan khusus browser. DOM browser, tab, navigasi, pengalihan URL, dan perilaku kontrol feed sengaja tidak tersedia.

### 7.1 Siklus hidup sumber

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Peristiwa bawaan asli

| Acara | Arti |
| --- | --- |
| tickEvent | Centang inang secara periodik. Opsi pendaftaran intervalMs dapat membatasi laju penangan. |
| pengatur waktu Berakhir | Hitung mundur yang dimiliki aturan mencapai nol. |
| tundaTekan | Pengguna menekan Mulai Tunda untuk grup Kustom. |
| panelAcara | Kontrol panel khusus digunakan. |
| acaraFile lokal | Tindakan folder lokal yang diminta selesai. |
| bukaAppEvent | Aplikasi yang dilacak akan terbuka. |
| tutupAppEvent | Aplikasi yang dilacak ditutup. |
| fokusAcara | Aplikasi latar depan berubah menjadi aplikasi. |
| tidak fokusAcara | Aplikasi latar depan berubah dari suatu aplikasi. |
| minimalkanEvent / batalkanminimizeEvent | Host melaporkan transisi minimalkan jendela yang didukung. |
| beralihAppEvent | Aplikasi latar depan berubah dari satu aplikasi ke aplikasi lainnya. |
| aplikasiChangedEvent | Siklus hidup aplikasi umum/peristiwa perubahan. |

Objek acara berisi tipe, groupId/groupID, groupName, URL/nama host yang setara, waktu, data, dan target. Untuk aplikasi asli, target memperlihatkan id, jenis, nama tampilan, nilai yang dinormalisasi, dan tag ketika target fokus cocok dengan target yang dikonfigurasi.

Data peristiwa siklus hidup aplikasi mencakup id/nama aplikasi saat ini, nama grup, snapshot aplikasi yang sedang berjalan, dan nilai spesifik peristiwa seperti bundleId, previousAppId, currentAppId, atau alasan perubahan.

### 7.3 API Peristiwa dan keputusan

Registri menyediakan on/register, off/unregister, unregisterAll, countRegistered, getEvent, dan getEvents. Prioritas yang lebih tinggi dijalankan terlebih dahulu; prioritas yang sama menjaga urutan pendaftaran. Registri memiliki batas penangan per grup.

Objek acara mendukung:

| Metode | Hasil |
| --- | --- |
| setHasil(-1) | Menghasilkan keputusan perisai/blok asli. Hasil string juga menjadi blok asli karena aturan desktop tidak memiliki target pengalihan browser. |
| izinkan(alasan) atau setResult(1) | Menghasilkan keputusan izin untuk acara tersebut. |
| setShieldMessage(pesan) | Atur pesan perisai/status yang menghadap manusia untuk blok asli. |
| stopPropagasi() | Hentikan penangan selanjutnya untuk kejadian saat ini. |
| blok(appId), buka blokir(appId) | Tambahkan/hapus blok aplikasi asli dinamis. |
| tutup(appId), buka(appId) | Minta tindakan tutup/buka asli yang didukung. |
| posting(jenis, data) | Mengirimkan peristiwa Kustom yang disarangkan dalam runtime asli. |

Waktu proses aplikasi memungkinkan pengatur waktu, persistensi, panel, log, operasi folder lokal, pembantu jendela aplikasi, dan utilitas pengklasifikasi URL. Ini sengaja memperlakukan DOM, navigasi, pengalihan, dan pembantu tab browser sebagai tidak tersedia/inert.

### 7.4 Pembantu asli

| Pembantu | Perilaku asli |
| --- | --- |
| dapatkanLogHelper | Memancarkan keputusan log aplikasi/popup/layar. |
| dapatkanTimerHelper | Membuat pengatur waktu maju/mundur dengan batas, langkah, cakupan/predikat domain, jeda/lanjutkan, pemeriksaan status, dan transisi pengatur waktu. Pengatur waktu tidak melindungi dirinya sendiri. |
| dapatkanPersistenceHelper | Status JSON per grup: dapatkan, setel, hapus, miliki, kunci, entri, hapus, ukuran. |
| dapatkanStorageHelper | Persistensi ditambah host placeholder permintaan asinkron; jangan berasumsi respons eksternal yang sinkron. |
| dapatkanWindowHelper | Membaca aplikasi yang sedang berjalan/berjalan dan meminta tindakan tutup/buka/blokir/buka blokir aplikasi. |
| dapatkanPanelHelper | Membuat snapshot panel asli yang divalidasi, kontrol, penangan inline, dan reaksi panelEvent. |
| dapatkan LocalFolderHelper | Antrean mengizinkan operasi relatif .txt, .csv, dan .json di bawah root yang diberikan pengguna. Penyelesaiannya adalah localFileEvent. |
| dapatkanDomainHelper/getDomainUtility | Pengklasifikasi URL dan platform untuk aturan yang juga mempertimbangkan nilai mirip URL. |
| dapatkanPlatformHelper/platform | Pengklasifikasi URL tetap tersedia; panggilan kontrol feed/DOM asli tidak aktif karena host desktop tidak memiliki DOM situs web. |

Panel khusus menggunakan kosakata kontrol deklaratif yang sama dengan runtime browser: teks, kotak centang, pilih, input teks, area teks, tombol, bagian, pengatur waktu, input angka, rentang, pengalih, radio, tanggal, waktu, warna, pin, dan html yang dibersihkan. Host asli memutuskan berapa banyak panel yang dapat ditampilkan pada platform saat ini.

## 8. Folder File Lokal

Folder File Lokal adalah batas opsional yang diberikan pengguna untuk aturan Kustom. Aturan dapat meminta pembacaan, penulisan, penambahan, daftar teks/CSV/JSON, pengujian keberadaan, dan operasi JSON. Jalur selalu relatif terhadap root yang dipilih. Jalur absolut, segmen traversal, komponen jalur tersembunyi, ekstensi yang tidak didukung, dan operasi di luar root ditolak.

Cabut folder tersebut ketika aturan tidak lagi membutuhkannya. Aturan harus menangani izin yang tidak tersedia dan hasil localFileEvent yang gagal; itu tidak boleh menganggap folder yang dipilih tetap diotorisasi setelah restart.

## 9. Jembatan aplikasi web

Jembatan ini merupakan sinkronisasi lokal opsional antara program Vault yang kompatibel. Aplikasi desktop asli dapat menghosting hub lokal; klien terhubung pada alamat lokal yang didukung.

Status koneksi adalah Mati, Tersambung, Terputus, Tersambung/Berjalan, dan Error. Menghubungkan suatu program tidak menggabungkan semua grup. Pengguna harus secara eksplisit menautkan grup pencocokan yang memenuhi syarat.

Untuk tautan grup:

1. Mulai hub asli di Pengaturan.
2. Hubungkan titik akhir Vault lain yang kompatibel.
3. Buat grup yang cocok dan tidak dibekukan dengan nama dan tipe yang sama.
4. Di bagian jembatan grup, pilih program dan sambungkan grup.

Grup yang tertaut membentuk sebuah cluster. Nilai kebijakan umum yang didukung, penggunaan, dan status tunda dapat disinkronkan saat anggota terhubung. Memutuskan sambungan akan menjeda sinkronisasi dan mempertahankan grup lokal. Target khusus browser, Tindakan kustom yang tidak didukung, dan kolom khusus platform tidak dijamin dapat ditransfer.

## 10. Impor, ekspor, reset, dan audit

Ekspor menyimpan satu representasi grup yang kompatibel. Impor memvalidasi/menormalkan data grup yang kompatibel dan tetap menerapkan keunikan nama lokal. Hapus Grup menghapus grup yang dipilih dan status terkaitnya. Hapus menghapus semua grup setelah konfirmasi. Reset ke default mempengaruhi pengaturan editor global; ekspor apa pun yang harus dipertahankan terlebih dahulu.

Sebelum mengandalkan aturan desktop:

1. Verifikasi Kontrol Perangkat diberikan.
2. Verifikasi identitas normalisasi target yang dipilih.
3. Verifikasi status aktif, jadwal, status beku, dan fase tunda.
4. Uji perilaku langsung, berwaktu, dan menghitung secara terpisah.
5. Untuk grup Kustom, Jalankan sumber persisnya dan uji setiap peristiwa aplikasi yang terdaftar.
6. Verifikasi kegagalan folder lokal serta operasi yang berhasil.
7. Verifikasi perilaku bridge offline/terhubung jika grup tertaut.

## 11. Catatan khusus platform

Konsep kebijakan inti bersifat sama, namun penerapan asli bersifat spesifik pada host:

| macOS | jendela |
| --- | --- |
| Target biasanya ditentukan berdasarkan pengidentifikasi paket aplikasi. Kontrol Perangkat dan penegakan gerbang negara izin macOS saat ini. | Target biasanya diselesaikan dengan jalur eksekusi atau nama proses yang dinormalisasi. Lapisan penegakan Windows memutuskan jendela/proses mana yang dapat dikelola. |

Referensi desktop ini sengaja tidak menjelaskan daftar blokir situs web, pemilih feed, klasifikasi pembuat YouTube, pengalihan browser, atau tindakan tab browser. Itu milik manual ekstensi Vault.
