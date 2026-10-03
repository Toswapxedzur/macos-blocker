# Panduan pengguna Mac Vault

Mac Vault memiliki tiga halaman: **Vault** memblokir aplikasi native, **Klasifikasi** memberi tag pada konten browser yang didukung, dan **Aktivitas** menampilkan penggunaan yang direkam. Ekstensi browser mengumpulkan konten yang didukung dan menerapkan pemblokiran browser. Pasang dan hubungkan di browser yang Anda gunakan.

## Mulai cepat

1. Di **Vault**, tambahkan grup pemblokiran dan target Apps, lalu pilih aplikasi dengan pemilih +.
2. Pilih perilaku pemblokiran grup dan aktifkan.
3. Di **Klasifikasi**, buat grup, pilih platform, lalu tambahkan tag beserta deskripsinya.
4. Pilih tingkat model lokal dan unduh jika perlu. Aktifkan tagging di setelan Klasifikasi dan lanjutkan grup.
5. Buka konten yang didukung di browser terhubung. Atur filter tag di grup pemblokiran browser jika tag ingin mengendalikan pemblokiran.

## Grup pemblokiran

**Grup pemblokiran** menerapkan kebijakan pemblokiran. **Grup Klasifikasi** memberi tag pada konten; grup ini sendiri tidak memblokir apa pun.

1. Tambahkan grup pemblokiran dan beri nama.
2. Pilih target pada **Berlaku untuk**.
3. Pilih kapan pemblokiran berlaku, lalu atur jadwal atau jatah waktu.
4. Aktifkan grup. Targetnya berbagi kebijakan grup tersebut.

Perubahan rutin tersimpan otomatis. Pesan kesalahan berarti perubahan tidak diterima; perbaiki kolom lalu coba lagi. Nonaktifkan grup untuk menghentikan kebijakannya sambil mempertahankan konfigurasi. **Hapus grup** menghapusnya. Seret grup untuk mengubah urutan. Beberapa grup dapat berlaku untuk satu target; menunda satu grup tidak menghapus pemblokiran grup lain.

**Ekspor** menyalin konfigurasi grup. **Impor** mengganti konfigurasi grup terpilih setelah konfirmasi.

### Jatah waktu dan jadwal

**Blokir segera** berlaku setiap kali grup aktif cocok dan jadwalnya berjalan. **Blokir setelah jatah waktu habis** mengizinkan penggunaan yang cocok hingga jatahnya habis.

Atur jatah dalam menit dan interval reset dalam jam. Batas bergulir menghitung penggunaan dalam jendela sebelumnya. Reset tengah malam memulai periode baru pada tengah malam waktu setempat, termasuk untuk batas bergulir.

Pilih hari aktif dan jendela waktu lokal opsional, satu per baris, seperti **09:00-12:00**. Daftar jendela kosong berlaku sepanjang hari yang dipilih. Jendela harus berakhir setelah waktu mulainya pada hari yang sama; bagi jadwal semalam menjadi beberapa hari.

### Penundaan sementara

Atur penundaan di setiap grup pemblokiran. **Jeda pemblokiran** menangguhkan kebijakan grup selama durasi jeda. **Tambahkan ke jatah waktu** menambah menit pakai ke grup dengan batas waktu. Hanya jatah tambahan yang digunakan yang dihitung sebagai waktu tunda. Jatah tambahan yang tidak dipakai kedaluwarsa saat reset berikutnya; untuk batas bergulir, setelah satu jendela atau lebih cepat pada tengah malam jika diaktifkan.

**Tunda aktivasi** menunda awal jeda sementara pemblokiran tetap berjalan. **Masa jeda** adalah waktu tunggu setelah penundaan berakhir sebelum permintaan berikutnya. **Konfirmasi wajib** menentukan jumlah langkah konfirmasi. Grup yang dibekukan hanya dapat ditunda jika diizinkan sebelum dibekukan.

### Kunci pengeditan dan PIN

**Bekukan** mencegah pengeditan rutin. Untuk mencairkan, diperlukan sepuluh konfirmasi dengan jarak lima detik, ditambah waktu tunggu yang diatur dan PIN enam digit jika tersedia. **Tunggu sebelum mencairkan** menerima 0–72 jam; 0 berarti tanpa waktu tunggu tambahan.

Saat grup dibekukan, waktu tunggu dapat diperpanjang dan PIN dapat ditambahkan jika belum ada. Syarat itu tidak dapat dilonggarkan sebelum grup dicairkan. Penghapusan juga tunduk pada waktu tunggu tersisa dan PIN.

### Grup tertaut

Gunakan **Tautkan** untuk menghubungkan grup yang dipilih secara eksplisit di program Vault lain. Grup tertaut berbagi nama, setelan kebijakan yang didukung, target, penggunaan, dan syarat pembekuan. Tiap program mengedit dan menerapkan jenis target yang didukungnya; entri target lain tetap tersedia bagi program tertaut. Membatalkan tautan mempertahankan setiap grup dan setelannya.

Jika anggota tertaut offline, pengeditan mungkin tidak tersedia. Buka Mac Vault dan browser tertaut untuk menyambung kembali. Kebijakan tersimpan lokal dapat terus berlaku saat anggota offline.

## Bantuan

Klik **i** kecil di samping kolom untuk melihat penjelasan. Klik di luarnya atau tekan Escape untuk menutup. Daftar berada di dalam kotak yang dapat digulir; gulir kotak untuk melihat entri lainnya. Pencarian memfilter daftar yang terlihat tanpa menghapus entri.

Aturan khusus memiliki [Panduan kode](../code-manual/id.md) tersendiri. Panduan itu menjelaskan editor, aktivasi, log, akses berkas, dan API yang didukung.

## Aplikasi native

Gunakan pemilih + pada target Apps untuk memilih aplikasi terpasang. **Blokir semua aplikasi kecuali ini** mengubah daftar menjadi daftar izin. Aplikasi sistem, browser, dan Vault sendiri dikecualikan dari pemblokiran aplikasi native.

Aplikasi yang diblokir diminta untuk berhenti. **Minta aplikasi yang diblokir berhenti lagi setiap (menit)** mengatur percobaan ulang. Pengalihan situs, jeda halaman, dan penyembunyian feed diterapkan ekstensi browser; semuanya bukan aksi aplikasi native.

## Klasifikasi

Grup Klasifikasi memberi tag pada konten dari platform yang ditetapkan dengan pohon tag dan setelan modelnya sendiri. Setiap platform hanya menjadi anggota satu grup. Pilih platform saat membuat grup; sesudahnya tidak dapat diubah. Jadwal dan filter grup pemblokiran tidak mengendalikan tagging.

Aktifkan tagging di setelan Klasifikasi. Gunakan **Jeda tagging / Lanjutkan tagging** terpisah untuk tiap grup. Mematikan rekaman feed platform di **Aktivitas → Rekaman** juga menghentikan tagging-nya.

### Tag dan setelan model

Buat tag, jelaskan maknanya, lalu atur atau hapus induknya di pohon tag. Seret tag untuk memindahkan cabangnya. Deskripsi yang jelas membantu model membedakan tag serupa. Setiap grup memiliki setelan sendiri.

- **Kecepatan ↔ Kualitas** memilih tingkat model lokal. Model besar memakai lebih banyak memori; kecepatan dan hasil bergantung pada Mac dan beban kerja. Unduhan digunakan bersama antarkelompok.
- **Ketat ↔ Luas** mengatur persyaratan keyakinan dan jumlah tag default.
- **Tag minimum / Tag maksimum** di Lainnya mengganti jumlah default tersebut. Ketat ↔ Luas tetap mengatur keyakinan untuk tag tambahan. Kosongkan salah satu kolom untuk memakai nilai defaultnya.
- **Instruksi tagging** menambahkan petunjuk opsional untuk grup ini.

Perubahan Klasifikasi rutin tersimpan otomatis. Tingkat yang dipilih harus diunduh sebelum dapat memberi tag. Grup yang memakai tingkat sama berbagi model yang dimuat; maksimal dua tingkat tetap dimuat sekaligus.

Koreksi tag item konten di ekstensi browser. Klik **+ tag**, cari tag Klasifikasi yang ada, lalu pilih satu untuk ditambahkan. Gunakan kontrol hapus tag atau pilih tag dan tekan Delete sekali untuk menghapusnya. **Tanpa tag** berarti tagging selesai tanpa tag; **Sedang diberi tag** berarti hasil masih menunggu. Koreksi membantu tagging berikutnya.

## Pengetahuan dan riset web

Pengetahuan menyimpan deskripsi singkat di Mac untuk model tagging lokal. **Sumber konten** mencakup kreator, akun, channel, dan komunitas. Deskripsi sumber menyertai kontennya. **Istilah dikenal** berlaku saat istilah muncul di judul.

Tambahkan sumber atau istilah beserta deskripsinya, atau kosongkan deskripsi untuk meminta riset jika diaktifkan. Saran kreator membantu menemukan sumber yang sudah dikumpulkan Klasifikasi. Daftar dengan enam entri atau lebih memiliki pencarian tepat di atasnya: Istilah dan Sumber konten tiap platform memiliki pencarian terpisah untuk nama, ID, atau deskripsi. Mengedit deskripsi memengaruhi tagging berikutnya; menghapus pengetahuan sumber tidak mencegah riset membuatnya kembali nanti.

### Atur penyedia riset

1. Buka **Setelan Klasifikasi → Kunci API & penyedia**.
2. Pilih jenis penyedia dan **Tambah penyedia**. Ini membuat konfigurasi, bukan menerbitkan kunci API.
3. Dapatkan kredensial dari penyedia tersebut dan masukkan. Untuk endpoint kustom yang kompatibel, atur juga field endpoint dan protokolnya.
4. Di **Riset web**, pilih penyedia dengan pencarian web bawaan. Ambil daftar modelnya dan pilih model riset. Gunakan pencarian pada pemilih model untuk mempersempit daftar; segarkan untuk mengambil ulang.
5. Baca pemberitahuan persetujuan dan aktifkan persetujuan. Pilih **Aktif**, **Nonaktif**, atau **Ikuti setelan Klasifikasi** untuk tiap grup.

**Atur riset web…** membuka setelan jika konfigurasi belum ada. Grup tidak dapat melewati persetujuan riset. **Uji koneksi** memastikan permintaan uji berhasil, bukan bahwa semua model mendukung riset. Model uji penyedia berbeda dari model riset yang dipilih.

Kunci disimpan di folder dukungan aplikasi pada Mac, bukan Keychain sistem. Kunci mengautentikasi permintaan ke penyedia yang dikonfigurasi; Vault tidak mengunggahnya ke server sendiri. Riset mengirim subjek publik yang disanitasi ke penyedia terpilih, bukan isi atau ringkasan konten privat. Baca pemberitahuan persetujuan untuk mengetahui field yang dikirim. Penggunaan penyedia juga mencakup uji koneksi dan permintaan daftar model.

Status riset menampilkan permintaan antrean, jeda percobaan ulang, kegagalan, dan penggunaan token hari ini. **Coba ulang subjek gagal sekarang** mengulangi kegagalan yang memenuhi syarat; tidak melewati batas harian atau persetujuan.

## Aktivitas

Aktivitas merekam penggunaan aplikasi yang diaktifkan, kunjungan situs, dan **Konten dilihat** yang didukung secara lokal. Grafik menunjukkan data rekaman; area kosong tidak membuktikan Mac sedang tidak aktif.

Pilih rentang tanggal. **Linimasa** menampilkan penggunaan pada waktu terjadinya; **Total** menjumlahkan durasi. **Interval waktu** menggabungkan penggunaan dalam tiap interval menjadi blok vertikal. **Warna** adalah legenda yang dapat diklik: pilih sumber untuk memfokuskan grafik. Pilih hari untuk melihat penggunaan sejak hari itu.

### Grup Aktivitas

Buat grup agar aplikasi dan situs terpilih muncul bersama di Penggunaan. **Gabungkan** memakai satu nama dan warna bagi anggotanya di seluruh Aktivitas. Grup Aktivitas mengatur penggunaan tercatat; terpisah dari grup pemblokiran atau Klasifikasi. Simpan editor grup Aktivitas secara eksplisit dengan **Simpan**.

### Rekaman dan retensi

Di **Rekaman**, nyalakan atau matikan rekaman untuk tiap kategori atau sumber. **Simpan selama** mengatur berapa lama riwayat dipertahankan; **Selamanya** menyimpannya tanpa kedaluwarsa otomatis. Pilihan per item dapat mengikuti setelan yang lebih luas. Mematikan rekaman menghentikan rekaman baru; menghapus riwayat menghapus entri yang sudah direkam.

Feed platform mengumpulkan konten yang ditampilkan di halaman platform yang didukung, baik dibuka maupun tidak. Feed berlabel **Tagging didukung** dapat memasok Klasifikasi saat rekaman aktif. Retensinya mengatur konten yang dikumpulkan secara terpisah dari penggunaan aplikasi dan situs. Grup Klasifikasi yang dijeda tidak otomatis mematikan rekaman.

## Setelan Klasifikasi

**Pembaruan paket tag** memilih kapan pembaruan paket tag terverifikasi berlaku: **Otomatis**, **Tanya dahulu**, atau **Manual**. Ini terpisah dari pengunduhan model lokal yang dipilih dalam grup. File model diunduh dari Hugging Face saat Anda memilih **Unduh**; gunakan progres/status grup dan kontrol **Batal** selama pengunduhan.

Pilih bahasa antarmuka di Setelan. Penjelasan kolom tersedia lewat tombol Info kecil dalam bahasa antarmuka terpilih.

## Penyimpanan dan pemecahan masalah

Perubahan Vault dan Klasifikasi yang rutin tersimpan otomatis. Pengeditan grup Aktivitas memakai **Simpan**. Menambah, menghapus, mengunduh model, menguji koneksi, dan mengambil daftar model tetap merupakan tindakan eksplisit.

Jika tag hilang, periksa koneksi browser, sakelar tagging global, status jeda grup, rekaman platform, dan unduhan model. Jika riset tidak berjalan, periksa persetujuan, pilihan grup, kredensial penyedia, model riset, dan status riset. Jika grup tertaut tak dapat diedit, sambungkan kembali programnya atau cairkan seperti yang ditunjukkan.
