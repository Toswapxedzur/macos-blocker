# Manual pengguna Mac Vault

Mac Vault memiliki tiga halaman: **Vault** memblokir app native, **Penandaan konten** memberi tag pada konten browser yang didukung, dan **Aktivitas** menampilkan penggunaan yang direkam. Ekstensi browser mengumpulkan konten yang didukung dan menerapkan pemblokiran browser. Instal dan hubungkan di browser yang digunakan.

## Mulai cepat

1. Di **Vault**, tambahkan blokir Grup dan target Apps, lalu pilih app dengan pemilih +.
2. Pilih perilaku pemblokiran dan aktifkan grup.
3. Di **Penandaan konten**, buat grup, pilih platformnya, dan tambahkan tag beserta deskripsi.
4. Buka Pengaturan → **Koneksi AI**, pilih ChatGPT subscription, OpenAI API, Gemini API, atau Grok API. Hubungkan akun atau masukkan key dan ambil model, lalu pilih koneksi/model di grup. Aktifkan tagging dan lanjutkan grup.
5. Buka konten yang didukung di browser terhubung. Tambahkan filter tag ke browser blokir Grup jika tag hendak mengendalikan pemblokiran.

## Grup pemblokiran

**Blokir Grup** menerapkan kebijakan pemblokiran. **Penandaan konten** memberi tag pada konten dan tidak memblokir sendiri. Tambahkan dan namai grup, pilih target di **Berlaku untuk**, tentukan kapan pemblokiran berlaku dan atur jadwal atau batas waktu, lalu aktifkan. Edit biasa tersimpan otomatis. Error berarti perubahan ditolak; perbaiki field lalu coba lagi. Menonaktifkan grup menghentikan kebijakan dengan tetap menyimpan konfigurasinya; **Hapus grup** menghapusnya. Seret grup untuk mengurutkan. Beberapa grup dapat berlaku untuk target sama; snooze satu grup tidak mengangkat blokir grup lain. **Ekspor** menyalin konfigurasi; **Impor** mengganti konfigurasi grup terpilih setelah konfirmasi.

### Batas waktu dan jadwal

**Block immediately** berlaku saat grup aktif cocok dan jadwalnya berjalan. **Block when the time allowance is used** mengizinkan penggunaan sampai jatah habis. Atur jatah dalam menit dan interval reset dalam jam. Batas bergulir menghitung penggunaan dalam window sebelumnya. Reset tengah malam memulai periode baru pada tengah malam lokal, termasuk batas bergulir. Pilih hari aktif dan window waktu lokal opsional, satu per baris, misalnya **09:00-12:00**. Daftar window kosong berlaku sepanjang hari terpilih. Window harus berakhir setelah dimulai pada hari yang sama; pisahkan jadwal semalam ke beberapa hari.

### Jeda

Atur snooze di tiap blokir Grup. **Pause blocking** menangguhkan kebijakan selama durasi jeda. **Add to the time allowance** menambahkan menit yang dapat dipakai pada grup dengan batas waktu. Hanya allowance tambahan yang dipakai dihitung sebagai waktu snooze. Tambahan yang tidak dipakai kedaluwarsa saat reset berikutnya; untuk batas bergulir setelah satu window, atau lebih cepat pada tengah malam jika diaktifkan. **Activation delay** menunda snooze sementara pemblokiran tetap berjalan. **Cooldown** adalah jeda setelah snooze berakhir sebelum permintaan berikutnya. **Required confirmations** menentukan jumlah langkah konfirmasi. Snooze pada grup beku hanya tersedia jika diizinkan sebelum dibekukan.

### Freeze dan PIN

**Freeze** mencegah edit biasa. Membuka freeze memerlukan sepuluh konfirmasi dengan jarak lima detik, waktu tunggu yang ditentukan, dan PIN enam digit. **Wait before unfreezing** menerima 0–72 jam; 0 berarti tanpa jeda. Saat beku, waktu tunggu dapat diperpanjang dan PIN dapat ditambahkan jika belum ada; syarat tidak dapat dilonggarkan sampai grup dibuka. Penghapusan juga mematuhi sisa waktu tunggu dan PIN.

### Grup tertaut

Gunakan **Tautkan** untuk menghubungkan grup yang dipilih secara eksplisit dari program Vault lain. Grup berbagi nama, pengaturan kebijakan yang didukung, target, penggunaan, dan kondisi freeze. Tiap program mengedit dan menerapkan jenis target yang didukungnya; entri target lain tetap tersedia bagi program tertaut. **Lepas tautan** memisahkan tetapi mempertahankan grup dan pengaturannya. Jika anggota offline, buka Mac Vault dan browser tertaut untuk menghubungkan kembali. Kebijakan tersimpan lokal dapat tetap berlaku saat anggota offline.

## Bantuan

Klik **i** kecil di samping field untuk melihat penjelasan; klik di luar atau tekan Escape untuk menutup. Daftar berada dalam kotak yang dapat digulir; pencarian menyaring yang terlihat tanpa menghapus entri. [Code manual](../code-manual/id.md) untuk custom rules menjelaskan editor, aktivasi, log, akses file, dan API.

## App native

Gunakan pemilih + pada target Apps untuk memilih app terpasang atau berjalan. Buka lagi untuk memperbarui daftar setelah meluncurkan app dari folder lain. **Blokir semua aplikasi selain yang tercantum di sini** menjadikan daftar sebagai allowlist. Mac Vault dapat memblokir app Apple biasa dan browser utuh; Mac Vault dan app yang berbagi bundle identifier tetap dilindungi. App yang diblokir diminta keluar; **Minta aplikasi yang diblokir keluar kembali setiap (menit)** mengatur percobaan ulang. Redirect situs, jeda halaman, dan penyembunyian feed diterapkan ekstensi browser, bukan tindakan app native.

## Penandaan konten

Grup Penandaan konten memberi tag pada konten platform yang ditetapkan memakai pohon tag dan pengaturan modelnya sendiri. Tiap platform milik satu grup; pilih saat membuat grup, tidak dapat diubah setelahnya. Jadwal dan filter blokir Grup tidak mengendalikan tagging. Aktifkan tagging di Pengaturan. Gunakan **Jeda penandaan / Lanjutkan penandaan** secara terpisah untuk tiap grup. Mematikan recording feed platform di **Aktivitas → Perekaman** juga menghentikan tagging-nya.

### Tag dan pengaturan model

Buat tag, jelaskan artinya, dan tetapkan atau hapus parent di pohon. Seret tag untuk memindahkan cabang. Deskripsi jelas membantu model membedakan tag serupa. Pengaturan tiap grup independen. **Confidence tag minimum** menetapkan tingkat bukti untuk setiap tag prediksi, 1–5. Grup baru mulai di 4 (dukungan kuat). Tidak ada jumlah tag sasaran; item dapat tidak mendapat tag. **Instruksi penandaan** menyimpan preferensi grup. Edit Penandaan konten biasa tersimpan otomatis. Setiap grup memakai koneksi, model, dan reasoning effort yang dipilih secara eksplisit.

### Koneksi AI

Pengaturan memiliki ChatGPT subscription, OpenAI API, Gemini API, dan Grok API. Langganan memakai login Vault dan paket yang memenuhi syarat. Key API mengikuti penagihan dan batas penggunaan provider terpilih. Pilih provider dan masukkan key tepat di bawah dropdown bersama. Perubahan key tersimpan otomatis; mengosongkan field menghapus key. Pilih **Ambil daftar model**, lalu pilih model di grup Penandaan konten atau custom-rule. Mengambil daftar model tidak otomatis memilihnya.

**Upaya penalaran** mengatur seberapa banyak model berpikir: Model default, Low, Medium, atau High jika didukung. Pilihan baru mulai di Medium; pilihan lama tetap tersimpan. Effort lebih tinggi dapat menambah waktu dan token. Web search selalu aktif untuk tagging; model menentukan kapan menggunakannya. Pilih model yang mendukung search dan structured tagging. Permintaan yang gagal/tidak tersedia mempertahankan hasil cache yang valid; item baru tetap belum terselesaikan sampai memilih **Coba ulang klasifikasi cloud**. Vault tidak mengganti provider otomatis. Tiap koneksi memiliki interval retry dan batas percobaan sendiri. Koreksi tag di ekstensi browser: klik **+ tag**, cari dan pilih tag; gunakan kontrol hapus atau pilih tag lalu tekan Delete sekali untuk menghapus. **Tanpa tag** berarti tagging selesai tanpa tag; **Sedang memberi tag** berarti hasil masih menunggu. Koreksi Anda menjadi acuan item tersebut.

## Aktivitas

Aktivitas merekam lokal penggunaan app aktif, kunjungan situs, dan **Konten yang dilihat** yang didukung. Grafik mencerminkan data yang direkam; area kosong tidak membuktikan Mac sedang idle. Pilih rentang tanggal. **Linimasa** menunjukkan penggunaan menurut jam; **Total** menjumlah durasi; **Interval waktu** menggabungkan penggunaan tiap interval menjadi blok vertikal. **Warna** adalah legenda yang dapat diklik untuk memfokuskan grafik pada sumber. Pilih hari untuk melihat penggunaan sejak hari itu.

### Grup Aktivitas

Buat grup untuk menampilkan app dan situs pilihannya bersama di Usage. **Merge** memakai satu nama dan warna untuk anggota di seluruh Aktivitas. Aktivitas group mengatur penggunaan terekam dan terpisah dari blokir Grup maupun Penandaan konten. Simpan editor Aktivitas group secara eksplisit dengan **Save**.

### Perekaman dan retensi

Di **Perekaman**, hidupkan atau matikan perekaman per kategori atau sumber. **Simpan** mengatur lama riwayat disimpan; **Selamanya** menyimpannya tanpa kedaluwarsa otomatis. Pilihan individual dapat mengikuti pengaturan luas. Mematikan perekaman menghentikan rekaman baru; menghapus riwayat menghapus entri. Feed platform mengumpulkan konten yang ditampilkan pada halaman platform yang didukung, dibuka atau tidak. Feed dengan **Penandaan didukung** dapat memasok Penandaan konten saat recording aktif. Retensinya terpisah dari penggunaan app dan situs. Pause pada grup Penandaan konten tidak otomatis mematikan recording.

## Pengaturan

Pilih bahasa antarmuka di Pengaturan. Penjelasan field tersedia melalui tombol Info dalam bahasa terpilih.

## Penyimpanan dan pemecahan masalah

Edit Vault dan Penandaan konten biasa tersimpan otomatis. Editor Aktivitas group memerlukan **Save**. Tambah, hapus, tes koneksi dan pengambilan daftar model adalah tindakan eksplisit. Jika tag hilang, periksa koneksi browser, sakelar tagging global, status pause, recording platform, koneksi/model terpilih dan kredensial. Untuk permintaan AI gagal, periksa koneksi/model, kredensial, batas penggunaan provider dan Log grup. Jika linked group tidak dapat diedit, hubungkan ulang programnya atau buka freeze sesuai petunjuk.
