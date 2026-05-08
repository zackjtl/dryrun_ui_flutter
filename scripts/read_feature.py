import pefile
import sys
import os


def get_string_resource(file_path, string_id):
    """
    從 Windows PE 檔案 (.exe/.dll) 中讀取指定 ID 的 STRINGTABLE 資源。
    """
    if not os.path.exists(file_path):
        return "錯誤: 找不到檔案 {0}".format(file_path)

    try:
        pe = pefile.PE(file_path, fast_load=True)
        pe.parse_data_directories()

        bundle_id = (string_id // 16) + 1
        index = string_id % 16

        if not hasattr(pe, 'DIRECTORY_ENTRY_RESOURCE'):
            return "錯誤: 該檔案不包含資源表"

        for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
            if entry.id == 6:  # RT_STRING
                for bundle in entry.directory.entries:
                    if bundle.id == bundle_id:
                        for lang in bundle.directory.entries:
                            data_rva = lang.data.struct.OffsetToData
                            size = lang.data.struct.Size
                            data = pe.get_data(data_rva, size)

                            pos = 0
                            for i in range(16):
                                if pos >= len(data):
                                    break

                                length = int.from_bytes(data[pos:pos+2], byteorder='little')
                                pos += 2

                                if i == index:
                                    if length == 0:
                                        return ""
                                    return data[pos:pos + length*2].decode("utf-16-le")

                                pos += length * 2

        return "找不到 ID 為 {0} 的字串".format(string_id)

    except Exception as e:
        return "解析失敗: {0}".format(str(e))


if __name__ == "__main__":
    target_exe = "MPTool.exe"

    ids_to_read = [1001, 1002]

    if len(sys.argv) >= 2:
        target_exe = sys.argv[1]

    print("-" * 40)
    print("目標檔案: {0}".format(target_exe))
    print("Python 版本: {0}".format(sys.version.split()[0]))
    print("-" * 40)

    for sid in ids_to_read:
        result = get_string_resource(target_exe, sid)
        print("ID {0}: {1}".format(sid, result))

    print("-" * 40)
