#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>
#include <aclapi.h>
#include <sddl.h>
#include <wincodec.h>
#include <shlwapi.h>
#include <vector>
#include <string>
#include <algorithm>
#include <climits>
#include "CVaultWindows.h"

static std::wstring wide(const char *value) {
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (length <= 0) return {};
    std::vector<wchar_t> result(length);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result.data(), length)) return {};
    return std::wstring(result.data());
}

uint32_t vault_windows_random(uint8_t *output, size_t length) {
    if (!output || length > ULONG_MAX) return ERROR_INVALID_PARAMETER;
    return BCryptGenRandom(nullptr, output, static_cast<ULONG>(length), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0 ? 0 : ERROR_GEN_FAILURE;
}

uint32_t vault_windows_protect(const uint8_t *input, size_t length, uint8_t **output, size_t *outputLength, int decrypt) {
    if (!input || !output || !outputLength || length > MAXDWORD) return ERROR_INVALID_PARAMETER;
    DATA_BLOB source{static_cast<DWORD>(length), const_cast<BYTE *>(input)}, destination{};
    // Current-user DPAPI: never use CRYPTPROTECT_LOCAL_MACHINE or prompt flags.
    BOOL success = decrypt
        ? CryptUnprotectData(&source, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &destination)
        : CryptProtectData(&source, L"Vault Classifier backup verifier", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &destination);
    if (!success) return GetLastError();
    *output = destination.pbData;
    *outputLength = destination.cbData;
    return 0;
}

void vault_windows_free(void *memory) { LocalFree(memory); }

uint32_t vault_windows_restrict_path(const char *path) {
    auto name = wide(path);
    if (name.empty()) return ERROR_INVALID_NAME;
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return GetLastError();
    DWORD length = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &length);
    std::vector<BYTE> user(length);
    if (!GetTokenInformation(token, TokenUser, user.data(), length, &length)) { DWORD error = GetLastError(); CloseHandle(token); return error; }
    CloseHandle(token);
    wchar_t *sid = nullptr;
    if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(user.data())->User.Sid, &sid)) return GetLastError();
    std::wstring policy = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + std::wstring(sid) + L")";
    LocalFree(sid);
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(policy.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return GetLastError();
    BOOL present = FALSE, defaulted = FALSE;
    PACL acl = nullptr;
    GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted);
    DWORD result = SetNamedSecurityInfoW(name.data(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, acl, nullptr);
    LocalFree(descriptor);
    return result;
}

template <typename T> struct ComPointer {
    T *value = nullptr;
    ~ComPointer() { if (value) value->Release(); }
    T **address() { return &value; }
    T *operator->() const { return value; }
};

uint32_t vault_windows_image_jpeg(const uint8_t *input, size_t length, uint8_t **output, size_t *outputLength) {
    if (!input || !output || !outputLength || length == 0 || length > 512 * 1024) return ERROR_INVALID_PARAMETER;
    HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsApartment = SUCCEEDED(apartment);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return static_cast<uint32_t>(apartment);
    HRESULT result = E_FAIL;
    {
        ComPointer<IWICImagingFactory> factory;
        ComPointer<IStream> source;
        ComPointer<IWICBitmapDecoder> decoder;
        ComPointer<IWICBitmapFrameDecode> frame;
        ComPointer<IWICBitmapScaler> scaler;
        ComPointer<IWICFormatConverter> converter;
        ComPointer<IWICBitmap> bitmap;
        ComPointer<IStream> stream;
        ComPointer<IWICBitmapEncoder> encoder;
        ComPointer<IWICBitmapFrameEncode> target;
        ComPointer<IPropertyBag2> properties;
        do {
            result = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.address()));
            if (FAILED(result)) break;
            source.value = SHCreateMemStream(input, static_cast<UINT>(length));
            if (!source.value) { result = E_OUTOFMEMORY; break; }
            if (FAILED(result = factory->CreateDecoderFromStream(source.value, nullptr, WICDecodeMetadataCacheOnLoad, decoder.address()))) break;
            if (FAILED(result = decoder->GetFrame(0, frame.address()))) break;
            if (FAILED(result = factory->CreateBitmapScaler(scaler.address()))) break;
            if (FAILED(result = scaler->Initialize(frame.value, 64, 64, WICBitmapInterpolationModeFant))) break;
            if (FAILED(result = factory->CreateFormatConverter(converter.address()))) break;
            if (FAILED(result = converter->Initialize(scaler.value, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) break;
            std::vector<BYTE> pixels(64 * 64 * 4), opaque(64 * 64 * 3);
            if (FAILED(result = converter->CopyPixels(nullptr, 64 * 4, static_cast<UINT>(pixels.size()), pixels.data()))) break;
            for (size_t index = 0; index < 64 * 64; ++index) {
                unsigned alpha = pixels[index * 4 + 3];
                for (size_t channel = 0; channel < 3; ++channel)
                    opaque[index * 3 + channel] = static_cast<BYTE>((pixels[index * 4 + channel] * alpha + 255 * (255 - alpha) + 127) / 255);
            }
            if (FAILED(result = factory->CreateBitmapFromMemory(64, 64, GUID_WICPixelFormat24bppBGR, 64 * 3, static_cast<UINT>(opaque.size()), opaque.data(), bitmap.address()))) break;
            if (FAILED(result = CreateStreamOnHGlobal(nullptr, TRUE, stream.address()))) break;
            if (FAILED(result = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, encoder.address()))) break;
            if (FAILED(result = encoder->Initialize(stream.value, WICBitmapEncoderNoCache))) break;
            if (FAILED(result = encoder->CreateNewFrame(target.address(), properties.address()))) break;
            PROPBAG2 option{}; option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
            VARIANT quality{}; quality.vt = VT_R4; quality.fltVal = 0.85f;
            properties->Write(1, &option, &quality);
            if (FAILED(result = target->Initialize(properties.value))) break;
            if (FAILED(result = target->SetSize(64, 64))) break;
            WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
            if (FAILED(result = target->SetPixelFormat(&format))) break;
            if (FAILED(result = target->WriteSource(bitmap.value, nullptr))) break;
            if (FAILED(result = target->Commit()) || FAILED(result = encoder->Commit())) break;
            STATSTG stat{};
            if (FAILED(result = stream->Stat(&stat, STATFLAG_NONAME))) break;
            HGLOBAL global = nullptr;
            if (FAILED(result = GetHGlobalFromStream(stream.value, &global))) break;
            size_t count = static_cast<size_t>(stat.cbSize.QuadPart);
            auto copy = static_cast<uint8_t *>(LocalAlloc(LMEM_FIXED, count));
            if (!copy) { result = E_OUTOFMEMORY; break; }
            auto bytes = GlobalLock(global);
            if (!bytes) { LocalFree(copy); result = E_FAIL; break; }
            memcpy(copy, bytes, count);
            GlobalUnlock(global);
            *output = copy; *outputLength = count;
        } while (false);
    }
    if (ownsApartment) CoUninitialize();
    return SUCCEEDED(result) ? 0 : static_cast<uint32_t>(result);
}

// Hold all handles without delete sharing. Reparse points, extra entries,
// hard-linked files and concurrent replacements are left untouched.
void vault_windows_prune_package(const char *parentPath, const char *name) {
    auto parent = wide(parentPath), component = wide(name);
    if (parent.empty() || component.empty() || component.find_first_of(L"/\\:") != std::wstring::npos) return;
    auto path = parent + L"\\" + component;
    HANDLE directory = CreateFileW(path.c_str(), FILE_LIST_DIRECTORY | DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (directory == INVALID_HANDLE_VALUE) return;
    BY_HANDLE_FILE_INFORMATION metadata{};
    if (!GetFileInformationByHandle(directory, &metadata) || !(metadata.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (metadata.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) { CloseHandle(directory); return; }
    WIN32_FIND_DATAW entry{};
    HANDLE listing = FindFirstFileW((path + L"\\*").c_str(), &entry);
    std::vector<std::wstring> names;
    if (listing != INVALID_HANDLE_VALUE) {
        do { if (wcscmp(entry.cFileName, L".") && wcscmp(entry.cFileName, L"..")) names.emplace_back(entry.cFileName); } while (FindNextFileW(listing, &entry));
        FindClose(listing);
    }
    std::sort(names.begin(), names.end());
    if (names != std::vector<std::wstring>{L"seed-package.json", L"signed-manifest.json"}) { CloseHandle(directory); return; }
    std::vector<HANDLE> children;
    bool safe = true;
    for (auto &child : names) {
        HANDLE file = CreateFileW((path + L"\\" + child).c_str(), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (file == INVALID_HANDLE_VALUE) { safe = false; break; }
        children.push_back(file);
        BY_HANDLE_FILE_INFORMATION info{};
        if (!GetFileInformationByHandle(file, &info) || (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) || info.nNumberOfLinks != 1) { safe = false; break; }
    }
    FILE_DISPOSITION_INFO disposition{TRUE};
    if (safe && children.size() == 2) {
        for (auto file : children) if (!SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof(disposition))) safe = false;
    }
    for (auto file : children) CloseHandle(file);
    if (safe) SetFileInformationByHandle(directory, FileDispositionInfo, &disposition, sizeof(disposition));
    CloseHandle(directory);
}
