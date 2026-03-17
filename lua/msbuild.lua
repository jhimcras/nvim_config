local M = {}

M.vc2010_environments = {
    VS100COMNTOOLS = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\Tools\]],
    VSINSTALLDIR = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\]],
    VCINSTALLDIR = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\]],
    FrameworkDir64 = [[C:\Windows\Microsoft.NET\Framework64]],
    FrameworkVersion64 = [[v4.0.30319]],
    Framework35Version = [[v3.5]],
    INCLUDE = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\INCLUDE;C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\ATLMFC\INCLUDE;c:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\include;]],
    LIB = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\LIB\amd64;C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\ATLMFC\LIB\amd64;c:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\lib\x64;]],
    LIBPATH = [[C:\Windows\Microsoft.NET\Framework64\v4.0.30319;C:\Windows\Microsoft.NET\Framework64\v3.5;C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\LIB\amd64;C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\ATLMFC\LIB\amd64;]],
    PATH = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\BIN\amd64;C:\Windows\Microsoft.NET\Framework64\v4.0.30319;C:\Windows\Microsoft.NET\Framework64\v3.5;C:\Program Files (x86)\Microsoft Visual Studio 10.0\VC\VCPackages;C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\IDE;C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\Tools;C:\Program Files (x86)\HTML Help Workshop;c:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\bin\NETFX 4.0 Tools\x64;c:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\bin\x64;c:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\bin;C:\Program Files (x86)\Intel\iCLS Client\;C:\Program Files\Intel\iCLS Client\;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0\;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\IPT;C:\Program Files\Intel\Intel(R) Management Engine Components\IPT;C:\Program Files\Microsoft SQL Server\130\Tools\Binn\;C:\Program Files\dotnet\;C:\Program Files\Microsoft DNX\Dnvm\;]] .. vim.g.original_path,
}

M.vc2013_x86_environments = {
    DevEnvDir=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\IDE\]],
    ExtensionSdkDir=[[C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1\ExtensionSDKs]],
    Framework40Version=[[v4.0]],
    FrameworkDir=[[C:\Windows\Microsoft.NET\Framework\]],
    FrameworkDIR32=[[C:\Windows\Microsoft.NET\Framework\]],
    FrameworkVersion=[[v4.0.30319]],
    FrameworkVersion32=[[v4.0.30319]],
    INCLUDE=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\INCLUDE;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\ATLMFC\INCLUDE;C:\Program Files (x86)\Windows Kits\8.1\include\shared;C:\Program Files (x86)\Windows Kits\8.1\include\um;C:\Program Files (x86)\Windows Kits\8.1\include\winrt;]],
    LIB=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\LIB;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\ATLMFC\LIB;C:\Program Files (x86)\Windows Kits\8.1\lib\winv6.3\um\x86;]],
    LIBPATH=[[C:\Windows\Microsoft.NET\Framework\v4.0.30319;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\LIB;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\ATLMFC\LIB;C:\Program Files (x86)\Windows Kits\8.1\References\CommonConfiguration\Neutral;C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1\ExtensionSDKs\Microsoft.VCLibs\12.0\References\CommonConfiguration\neutral;]],
    Path=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\IDE\CommonExtensions\Microsoft\TestWindow;C:\Program Files (x86)\Microsoft SDKs\F#\3.1\Framework\v4.0\;C:\Program Files (x86)\MSBuild\12.0\bin;C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\IDE\;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\BIN;C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\Tools;C:\Windows\Microsoft.NET\Framework\v4.0.30319;C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\VCPackages;C:\Program Files (x86)\HTML Help Workshop;C:\Program Files (x86)\Microsoft Visual Studio 12.0\Team Tools\Performance Tools;C:\Program Files (x86)\Windows Kits\8.1\bin\x86;C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\;C:\Program Files (x86)\Python38-32\Scripts\;C:\Program Files (x86)\Python38-32\;C:\Program Files (x86)\Microsoft\Edge\Application;c:\oracle\;c:\oracle\bin;c:\oracle\;c:\oracle\bin;C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0\;C:\Windows\System32\OpenSSH\;C:\Program Files\dotnet\;C:\Users\HHI\AppData\Local\Microsoft\WindowsApps;C:\oracle;c:\oracle\bin;C:\Siemens\NX1926\CAPITALINTEGRATION\capitalnxremote\;C:\Python37;C:\Python37\Scripts;C:\Windows\system32;C:\Siemens\Teamcenter12_4Tier\tccs\bin;C:\Siemens\Teamcenter12_4Tier\tccs\lib;C:\Siemens\Teamcenter12_4Tier\portal;C:\Oracle;C:\Oracle\bin;C:\oracle;c:\oracle\bin;C:\Python37;C:\Python37\Scripts;C:\Windows\system32;C:\Siemens\Teamcenter12_4Tier\tccs\bin;C:\Siemens\Teamcenter12_4Tier\tccs\lib;C:\Siemens\Teamcenter12_4Tier\portal;C:\Oracle;C:\Oracle\bin;C:\Program Files\Git\cmd;C:\Program Files (x86)\Windows Kits\8.1\Windows Performance Toolkit\;C:\Program Files\Microsoft SQL Server\110\Tools\Binn\;C:\Program Files (x86)\Microsoft SDKs\TypeScript\1.0\;C:\Program Files\Microsoft SQL Server\120\Tools\Binn\;C:\Program Files\Neovim\bin;C:\Program Files\doxygen\bin;C:\Program Files\LLVM\bin;C:\Program Files\neovim-qt 0.2.18\bin;C:\Program Files\CMake\bin;C:\Program Files\Neovide\;C:\Python37;C:\Python37\Scripts;C:\Windows\system32;C:\Siemens\Teamcenter12_4Tier\tccs\bin;C:\Siemens\Teamcenter12_4Tier\tccs\lib;C:\Siemens\Teamcenter12_4Tier\portal;C:\Oracle;C:\Oracle\bin;D:\tools\bin;D:\tools\jdk-22.0.2\bin;D:\tools\cloc;D:\tools\coreutils-8.32\bin;C:\Users\Admin\Squish for Qt 6.7.2\bin;C:\Qt\Qt5.7.1\5.7\msvc2013\bin;;C:\Program Files\OpenCppCoverage]],
    VCINSTALLDIR=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\]],
    VisualStudioVersion=[[12.0]],
    VS110COMNTOOLS=[[C:\Program Files (x86)\Microsoft Visual Studio 11.0\Common7\Tools\]],
    VS120COMNTOOLS=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\Common7\Tools\]],
    VSINSTALLDIR=[[C:\Program Files (x86)\Microsoft Visual Studio 12.0\]],
    WindowsSdkDir=[[C:\Program Files (x86)\Windows Kits\8.1\]],
    WindowsSDK_ExecutablePath_x64=[[C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\x64\]],
    WindowsSDK_ExecutablePath_x86=[[C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\]],
}

M.vc2019_environments = {
    VS160COMNTOOLS = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\Tools\]],
    VSINSTALLDIR = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\]],
    VCINSTALLDIR = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\]],
    FrameworkDir64 = [[C:\WINDOWS\Microsoft.NET\Framework64]],
    FrameworkVersion64 = [[v4.0.30319]],
    Framework40Version=[[v4.0]],
    INCLUDE = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\ATLMFC\include;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\include;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\include\um;C:\Program Files (x86)\Windows Kits\10\include\10.0.18362.0\ucrt;C:\Program Files (x86)\Windows Kits\10\include\10.0.18362.0\shared;C:\Program Files (x86)\Windows Kits\10\include\10.0.18362.0\um;C:\Program Files (x86)\Windows Kits\10\include\10.0.18362.0\winrt;C:\Program Files (x86)\Windows Kits\10\include\10.0.18362.0\cppwinrt]],
    LIB = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\ATLMFC\lib\x64;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\lib\x64;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\lib\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.18362.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.18362.0\um\x64;]],
    LIBPATH = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\ATLMFC\lib\x64;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\lib\x64;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\lib\x86\store\references;C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.18362.0;C:\Program Files (x86)\Windows Kits\10\References\10.0.18362.0;C:\WINDOWS\Microsoft.NET\Framework\v4.0.30319;]],
    PATH = [[C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\bin\HostX86\x64;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\14.29.30133\bin\HostX86\x86;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\IDE\VC\VCPackages;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\IDE\CommonExtensions\Microsoft\TestWindow;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\MSBuild\Current\bin\Roslyn;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Team Tools\Performance Tools\x64;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Team Tools\Performance Tools;C:\Program Files (x86)\Microsoft Visual Studio\Shared\Common\VSPerfCollectionTools\vs2019\\x64;C:\Program Files (x86)\Microsoft Visual Studio\Shared\Common\VSPerfCollectionTools\vs2019\;C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\;C:\Program Files (x86)\Windows Kits\10\bin\10.0.18362.0\x86;C:\Program Files (x86)\Windows Kits\10\bin\x86;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\\MSBuild\Current\Bin;C:\WINDOWS\Microsoft.NET\Framework\v4.0.30319;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\IDE\;C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\Common7\Tools\;C:\Windows\system32;]],
    IgnoreWarnIntDirInTempDetected='true',
}

M.vc2022_environments = {
    ExtensionSdkDir = [[C:\Program Files (x86)\Microsoft SDKs\Windows Kits\10\ExtensionSDKs]],
    EXTERNAL_INCLUDE = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\include;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\ATLMFC\include;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\VS\include;C:\Program Files (x86)\Windows Kits\10\include\10.0.22000.0\ucrt;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\um;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\shared;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\winrt;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\cppwinrt;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\include\um]],
    Framework40Version = [[v4.0]],
    FrameworkDir = [[C:\WINDOWS\Microsoft.NET\Framework64\]],
    FrameworkDIR64 = [[C:\WINDOWS\Microsoft.NET\Framework64]],
    FrameworkVersion = [[v4.0.30319]],
    FrameworkVersion64 = [[v4.0.30319]],
    INCLUDE = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\include;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\ATLMFC\include;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\VS\include;C:\Program Files (x86)\Windows Kits\10\include\10.0.22000.0\ucrt;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\um;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\shared;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\winrt;C:\Program Files (x86)\Windows Kits\10\\include\10.0.22000.0\\cppwinrt;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\include\um]],
    LIB = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\ATLMFC\lib\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\lib\x64;C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\lib\um\x64;C:\Program Files (x86)\Windows Kits\10\lib\10.0.22000.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\10\\lib\10.0.22000.0\\um\x64]],
    LIBPATH = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\ATLMFC\lib\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\lib\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\lib\x86\store\references;C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.22000.0;C:\Program Files (x86)\Windows Kits\10\References\10.0.22000.0;C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319]],
    NETFXSDKDir = [[C:\Program Files (x86)\Windows Kits\NETFXSDK\4.6.1\]],
    Path = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\bin\HostX64\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\VC\VCPackages;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\TestWindow;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer;C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\bin\Roslyn;C:\Program Files\Microsoft Visual Studio\2022\Professional\Team Tools\Performance Tools\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\Team Tools\Performance Tools;C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\x64\;C:\Program Files (x86)\Windows Kits\10\bin\10.0.22000.0\\x64;C:\Program Files (x86)\Windows Kits\10\bin\\x64;C:\Program Files\Microsoft Visual Studio\2022\Professional\\MSBuild\Current\Bin\amd64;C:\WINDOWS\Microsoft.NET\Framework64\v4.0.30319;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\;C:\Program Files (x86)\Common Files\Oracle\Java\javapath;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\iCLS\;C:\Program Files\Intel\Intel(R) Management Engine Components\iCLS\;C:\WINDOWS\system32;C:\WINDOWS;C:\WINDOWS\System32\Wbem;C:\WINDOWS\System32\WindowsPowerShell\v1.0\;C:\WINDOWS\System32\OpenSSH\;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files\CMake\bin;C:\Program Files\CameraLink\Serial;C:\Program Files\Git\cmd;D:\bin;C:\Program Files (x86)\mingw-w64\i686-8.1.0-posix-dwarf-rt_v6-rev0\mingw32\bin;C:\Program Files (x86)\NVIDIA Corporation\PhysX\Common;d:\workspace\lua-language-server\3rd\luamake;C:\Users\LG-User\.cargo\bin;C:\Users\LG-User\scoop\shims;C:\Users\LG-User\AppData\Local\Microsoft\WindowsApps;D:\libs\lua\bin;D:\libs\opencv\build\x64\vc15\bin;C:\Program Files\Microsoft Office\Office15;d:\tools\rust-analyzer;C:\Program Files\LLVM\bin;C:\Users\LG-User\AppData\Local\Programs\Python\Python310\Scripts;D:\tools\coreutils\bin;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\VC\Linux\bin\ConnectionManagerExe]],
    VCIDEInstallDir = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\VC\]],
    VCINSTALLDIR = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\]],
    VCToolsInstallDir = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.34.31933\]],
    VCToolsRedistDir = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Redist\MSVC\14.34.31931\]],
    VCToolsVersion = [[14.34.31933]],
    VisualStudioVersion = [[17.0]],
    VS100COMNTOOLS = [[C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\Tools\]],
    VS140COMNTOOLS = [[C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\Tools\]],
    VS170COMNTOOLS = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\]],
    VSCMD_ARG_app_plat = [[Desktop]],
    VSCMD_ARG_HOST_ARCH = [[x64]],
    VSCMD_ARG_TGT_ARCH = [[x64]],
    VSCMD_VER = [[17.4.1]],
    VSINSTALLDIR = [[C:\Program Files\Microsoft Visual Studio\2022\Professional\]],
    WindowsLibPath = [[C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.22000.0;C:\Program Files (x86)\Windows Kits\10\References\10.0.22000.0]],
    WindowsSdkBinPath = [[C:\Program Files (x86)\Windows Kits\10\bin\]],
    WindowsSdkDir = [[C:\Program Files (x86)\Windows Kits\10\]],
    WindowsSDKLibVersion = [[10.0.22000.0\]],
    WindowsSdkVerBinPath = [[C:\Program Files (x86)\Windows Kits\10\bin\10.0.22000.0\]],
    WindowsSDKVersion = [[10.0.22000.0\]],
    WindowsSDK_ExecutablePath_x64 = [[C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\x64\]],
    WindowsSDK_ExecutablePath_x86 = [[C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\]],
    WSLENV = [[WT_SESSION::WT_PROFILE_ID]],
    WT_PROFILE_ID = [[{81fa2506-f91b-57a6-9e71-8bc7931702ee}]],
    WT_SESSION = [[087c04bf-1302-401d-b40b-c4229b9eb2e1]],
    __DOTNET_ADD_64BIT = [[1]],
    __DOTNET_PREFERRED_BITNESS = [[64]],
    __VSCMD_PREINIT_PATH = [[C:\Program Files (x86)\Common Files\Oracle\Java\javapath;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\iCLS\;C:\Program Files\Intel\Intel(R) Management Engine Components\iCLS\;C:\WINDOWS\system32;C:\WINDOWS;C:\WINDOWS\System32\Wbem;C:\WINDOWS\System32\WindowsPowerShell\v1.0\;C:\WINDOWS\System32\OpenSSH\;C:\Program Files (x86)\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files\Intel\Intel(R) Management Engine Components\DAL;C:\Program Files\CMake\bin;C:\Program Files\CameraLink\Serial;C:\Program Files\Git\cmd;D:\bin;C:\Program Files (x86)\mingw-w64\i686-8.1.0-posix-dwarf-rt_v6-rev0\mingw32\bin;C:\Program Files (x86)\NVIDIA Corporation\PhysX\Common;d:\workspace\lua-language-server\3rd\luamake;C:\Users\LG-User\.cargo\bin;C:\Users\LG-User\scoop\shims;C:\Users\LG-User\AppData\Local\Microsoft\WindowsApps;D:\libs\lua\bin;D:\libs\opencv\build\x64\vc15\bin;C:\Program Files\Microsoft Office\Office15;d:\tools\rust-analyzer;C:\Program Files\LLVM\bin;C:\Users\LG-User\AppData\Local\Programs\Python\Python310\Scripts;D:\tools\coreutils\bin]],
}

function M.builder(version, slnfile, configuration, rebuild, platform)
    local builder_in_general = {
        cmd = 'msbuild',
        args = {
            '/nologo',
            '/property:configuration=' .. (configuration and configuration or 'release') .. ';platform=' .. (platform and platform or 'x64'),
            '/maxCpuCount:2',
            '/verbosity:minimal',
            '/consoleloggerparameters:ForceNoAlign;NoItemAndPropertyList',
            slnfile,
        },
        highlight = {
            warning = 'Todo';
            error = 'Error';
        },
        position = { orientation = 'horizontal', size = 15 },
    }
    if rebuild then
        builder_in_general.args[#builder_in_general.args+1] = '/target:rebuild'
    end
    if version == 'VS2019' then
        return vim.tbl_extend('force', builder_in_general, { env = M.vc2019_environments })
    elseif version == 'VS2022' then
        return vim.tbl_extend('force', builder_in_general, { env = M.vc2022_environments })
    elseif version == 'VS2010' then
        return vim.tbl_extend('force', builder_in_general, { env = M.vc2010_environments })
    end
end

return M
