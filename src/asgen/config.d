/*
 * Copyright (C) 2016-2018 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module asgen.config;

import std.stdio;
import std.array;
import std.string : format, toLower;
import std.path : dirName, buildPath, buildNormalizedPath;
import std.conv : to;
import std.json;
import std.typecons;
import std.file : getcwd, thisExePath, exists;

public import appstream.c.types : FormatVersion;

import asgen.utils : existsAndIsDir, randomString, ImageSize;
import asgen.logging;
import asgen.defines : DATADIR;


/**
 * Describes a suite in a software repository.
 **/
struct Suite
{
    string name;
    int dataPriority = 0;
    string baseSuite;
    string iconTheme;
    string[] sections;
    string[] architectures;
    bool isImmutable;
}

/**
 * The AppStream metadata type we want to generate.
 **/
enum DataType
{
    XML,
    YAML
}

/**
 * Distribution-specific backends.
 **/
enum Backend
{
    Unknown,
    Dummy,
    Debian,
    Ubuntu,
    Archlinux,
    RpmMd
}

/**
 * Generator features that can be toggled by the user.
 */
enum GeneratorFeature
{
    NONE = 0,
    PROCESS_DESKTOP     = 1 << 0,
    VALIDATE            = 1 << 1,
    NO_DOWNLOADS        = 1 << 2,
    STORE_SCREENSHOTS   = 1 << 3,
    OPTIPNG             = 1 << 4,
    METADATA_TIMESTAMPS = 1 << 5,
    IMMUTABLE_SUITES    = 1 << 6,
    PROCESS_FONTS       = 1 << 7,
    ALLOW_ICON_UPSCALE  = 1 << 8,
    PROCESS_GSTREAMER   = 1 << 9,
}

/// A list of valid icon sizes that we recognize in AppStream
public immutable allowedIconSizes  = [ImageSize (48),  ImageSize (48, 48, 2),
                                      ImageSize (64),  ImageSize (64, 64, 2),
                                      ImageSize (128), ImageSize (128, 128, 2)];

/**
 * Policy on a single icon size.
 */
struct IconPolicy
{
    ImageSize iconSize; /// Size of the icon this policy is about
    bool storeCached;   /// True if the icon should be stored in an icon tarball and be cached locally.
    bool storeRemote;   /// True if this icon should be stored remotely and fetched on demand

    bool storeIcon () @property const
    {
        return storeCached || storeRemote;
    }

    this (ImageSize size, bool cached, bool remote)
    {
        iconSize = size;
        storeCached = cached;
        storeRemote = remote;
    }
}

/**
 * The global configuration for the metadata generator.
 */
final class Config
{
private:
    string workspaceDir;
    string exportDir;

    string tmpDir;

    // Thread local
    static bool instantiated_;

    // Thread global
    __gshared Config instance_;

    this () {
        formatVersion = FormatVersion.V0_12;
    }

public:
    FormatVersion formatVersion;
    string projectName;
    string archiveRoot;
    string mediaBaseUrl;
    string htmlBaseUrl;

    Backend backend;
    Suite[] suites;
    string[] oldsuites;
    DataType metadataType;
    uint enabledFeatures; // bitfield

    bool[string] allowedCustomKeys; // set of allowed keys in <custom/> tags

    string dataExportDir;
    string hintsExportDir;
    string mediaExportDir;
    string htmlExportDir;

    IconPolicy[] iconSettings;

    string caInfo;

    static Config get ()
    {
        if (!instantiated_) {
            synchronized (Config.classinfo) {
                if (!instance_)
                    instance_ = new Config ();

                instantiated_ = true;
            }
        }

        return instance_;
    }

    @property
    string formatVersionStr ()
    {
        import asgen.bindings.appstream_utils : as_format_version_to_string;
        import std.string : fromStringz;

        auto ver = fromStringz (as_format_version_to_string (formatVersion));
        return ver.to!string;
    }

    @property
    string databaseDir () const
    {
        return buildPath (workspaceDir, "db");
    }

    @property
    string cacheRootDir () const
    {
        return buildPath (workspaceDir, "cache");
    }

    @property
    string templateDir () {
        // find a suitable template directory
        // first check the workspace
        auto tdir = buildPath (workspaceDir, "templates");
        tdir = getVendorTemplateDir (tdir, true);

        if (tdir is null) {
            immutable exeDir = dirName (thisExePath ());
            tdir = buildNormalizedPath (exeDir, "..", "..", "..", "data", "templates");
            tdir = getVendorTemplateDir (tdir);

            if (tdir is null) {
                tdir = getVendorTemplateDir (buildPath (DATADIR, "templates"));

                if (tdir is null) {
                    tdir = buildNormalizedPath (exeDir, "..", "data", "templates");
                    tdir = getVendorTemplateDir (tdir);
                }
            }
        }

        return tdir;
    }

    /**
     * Helper function to determine a vendor template directory.
     */
    private string getVendorTemplateDir (const string dir, bool allowRoot = false) @safe
    {
        string tdir;
        if (projectName !is null) {
            tdir = buildPath (dir, projectName.toLower ());
            if (existsAndIsDir (tdir))
                return tdir;
        }
        tdir = buildPath (dir, "default");
        if (existsAndIsDir (tdir))
            return tdir;
        if (allowRoot) {
            if (existsAndIsDir (dir))
                return dir;
        }

        return null;
    }

    private void setFeature (GeneratorFeature feature, bool enabled)
    {
        if (enabled)
            enabledFeatures |= feature;
        else
            disableFeature (feature);
    }

    private void disableFeature (GeneratorFeature feature)
    {
        enabledFeatures &= ~feature;
    }

    bool featureEnabled (GeneratorFeature feature)
    {
        return (enabledFeatures & feature) > 0;
    }

    void loadFromFile (string fname, string enforcedWorkspaceDir = null)
    {
        // read the configuration JSON file
        auto f = File (fname, "r");
        string jsonData;
        string line;
        while ((line = f.readln ()) !is null)
            jsonData ~= line;

        JSONValue root = parseJSON (jsonData);

        if ("WorkspaceDir" in root) {
            workspaceDir = root["WorkspaceDir"].str;
        } else {
            workspaceDir = dirName (fname);
            if (workspaceDir.empty)
                workspaceDir = getcwd ();
        }

        // allow overriding the workspace location
        if (!enforcedWorkspaceDir.empty)
            workspaceDir = enforcedWorkspaceDir;

        this.projectName = "Unknown";
        if ("ProjectName" in root)
            this.projectName = root["ProjectName"].str;

        this.archiveRoot = root["ArchiveRoot"].str;

        this.mediaBaseUrl = "";
        if ("MediaBaseUrl" in root)
            this.mediaBaseUrl = root["MediaBaseUrl"].str;

        this.htmlBaseUrl = "";
        if ("HtmlBaseUrl" in root)
            this.htmlBaseUrl = root["HtmlBaseUrl"].str;

        // set the default export directory locations, allow people to override them in the config
        exportDir      = buildPath (workspaceDir, "export");
        mediaExportDir = buildPath (exportDir, "media");
        dataExportDir  = buildPath (exportDir, "data");
        hintsExportDir = buildPath (exportDir, "hints");
        htmlExportDir  = buildPath (exportDir, "html");

        if ("ExportDirs" in root) {
            auto edirs = root["ExportDirs"].object;
            foreach (dirId; edirs.byKeyValue) {
                switch (dirId.key) {
                    case "Media":
                        mediaExportDir = dirId.value.str;
                        break;
                    case "Data":
                        dataExportDir = dirId.value.str;
                        break;
                    case "Hints":
                        hintsExportDir = dirId.value.str;
                        break;
                    case "Html":
                        htmlExportDir = dirId.value.str;
                        break;
                    default:
                        logWarning ("Unknown export directory specifier in config: %s", dirId.key);
                }
            }
        }

        this.metadataType = DataType.XML;
        if ("MetadataType" in root)
            if (root["MetadataType"].str.toLower () == "yaml")
                this.metadataType = DataType.YAML;

        if ("CAInfo" in root)
            this.caInfo = root["CAInfo"].str;

        // allow specifying the AppStream format version we build data for.
        if ("FormatVersion" in root) {
            immutable versionStr = root["FormatVersion"].str;

            switch (versionStr) {
            case "0.8":
                formatVersion = FormatVersion.V0_8;
                break;
            case "0.9":
                formatVersion = FormatVersion.V0_9;
                break;
            case "0.10":
                formatVersion = FormatVersion.V0_10;
                break;
            case "0.11":
                formatVersion = FormatVersion.V0_11;
                break;
            case "0.12":
                formatVersion = FormatVersion.V0_12;
                break;
            default:
                logWarning ("Configuration tried to set unknown AppStream format version '%s'. Falling back to default version.", versionStr);
                break;
            }
        }

        // we default to the Debian backend for now
        auto backendName = "debian";
        if ("Backend" in root)
            backendName = root["Backend"].str.toLower ();
        switch (backendName) {
            case "dummy":
                this.backend = Backend.Dummy;
                this.metadataType = DataType.YAML;
                break;
            case "debian":
                this.backend = Backend.Debian;
                this.metadataType = DataType.YAML;
                break;
            case "ubuntu":
                this.backend = Backend.Ubuntu;
                this.metadataType = DataType.YAML;
                break;
            case "arch":
            case "archlinux":
                this.backend = Backend.Archlinux;
                this.metadataType = DataType.XML;
                break;
            case "mageia":
            case "rpmmd":
                this.backend = Backend.RpmMd;
                this.metadataType = DataType.XML;
                break;
            default:
                break;
        }

        auto hasImmutableSuites = false;
        foreach (suiteName; root["Suites"].object.byKey ()) {
            Suite suite;
            suite.name = suiteName;

            // having a suite named "pool" will result in the media pool being copied on
            // itself if immutableSuites is used. Since 'pool' is a bad suite name anyway,
            // we error out early on this.
            if (suiteName == "pool")
                throw new Exception ("The name 'pool' is forbidden for a suite.");

            auto sn = root["Suites"][suiteName];
            if ("dataPriority" in sn)
                suite.dataPriority = to!int (sn["dataPriority"].integer);
            if ("baseSuite" in sn)
                suite.baseSuite = sn["baseSuite"].str;
            if ("useIconTheme" in sn)
                suite.iconTheme = sn["useIconTheme"].str;
            if ("sections" in sn)
                foreach (sec; sn["sections"].array)
                    suite.sections ~= sec.str;
            if ("architectures" in sn)
                foreach (arch; sn["architectures"].array)
                    suite.architectures ~= arch.str;
            if ("immutable" in sn) {
                suite.isImmutable = sn["immutable"].type == JSON_TYPE.TRUE;
                if (suite.isImmutable)
                    hasImmutableSuites = true;
            }

            suites ~= suite;
        }

        if ("Oldsuites" in root.object) {
            import std.algorithm.iteration : map;

            oldsuites = map!"a.str"(root["Oldsuites"].array).array;
        }

        // icon policy
        if ("Icons" in root.object) {
            import std.algorithm : canFind;

            iconSettings.reserve (4);
            auto iconsObj = root["Icons"].object;
            foreach (iconString; iconsObj.byKey) {
                auto iconObj = iconsObj[iconString];

                IconPolicy ipolicy;
                ipolicy.iconSize = ImageSize (iconString);
                if (!allowedIconSizes.canFind (ipolicy.iconSize)) {
                    logError ("Invalid icon size '%s' selected in configuration, icon policy has been ignored.", iconString);
                    continue;
                }
                if (ipolicy.iconSize.width < 0) {
                    logError ("Malformed icon size '%s' found in configuration, icon policy has been ignored.", iconString);
                    continue;
                }

                if ("remote" in iconObj)
                    ipolicy.storeRemote = iconObj["remote"].type == JSON_TYPE.TRUE;
                if ("cached" in iconObj)
                    ipolicy.storeCached = iconObj["cached"].type == JSON_TYPE.TRUE;

                if (ipolicy.storeIcon)
                    iconSettings ~= ipolicy;
            }

            // Sanity check
            bool defaultSizeFound = false;
            foreach (ref ipolicy; iconSettings) {
                if (ipolicy.iconSize == ImageSize (64)) {
                    defaultSizeFound = true;
                    if (!ipolicy.storeCached) {
                        logError ("The icon size 64x64 must always be present and be allowed to be cached. Configuration has been adjusted.");
                        ipolicy.storeCached = true;
                        break;
                    }
                }
            }
            if (!defaultSizeFound) {
                logError ("The icon size 64x64 must always be present and be allowed to be cached. Configuration has been adjusted.");
                IconPolicy ipolicy;
                ipolicy.iconSize = ImageSize (64);
                ipolicy.storeCached = true;
                iconSettings ~= ipolicy;
            }

        } else {
            // no explicit icon policy was given, so we use a default policy

            iconSettings.reserve (6);
            iconSettings ~= IconPolicy (ImageSize (48), true, false);
            iconSettings ~= IconPolicy (ImageSize (48, 48, 2), true, false);
            iconSettings ~= IconPolicy (ImageSize (64), true, false);
            iconSettings ~= IconPolicy (ImageSize (64, 64, 2), true, false);
            iconSettings ~= IconPolicy (ImageSize (128), true, true);
            iconSettings ~= IconPolicy (ImageSize (128, 128, 2), true, true);
        }

        if ("AllowedCustomKeys" in root.object)
            foreach (ref key; root["AllowedCustomKeys"].array)
                allowedCustomKeys[key.str] = true;

        // Enable features which are default-enabled
        setFeature (GeneratorFeature.PROCESS_DESKTOP, true);
        setFeature (GeneratorFeature.VALIDATE, true);
        setFeature (GeneratorFeature.STORE_SCREENSHOTS, true);
        setFeature (GeneratorFeature.OPTIPNG, true);
        setFeature (GeneratorFeature.METADATA_TIMESTAMPS, true);
        setFeature (GeneratorFeature.IMMUTABLE_SUITES, true);
        setFeature (GeneratorFeature.PROCESS_FONTS, true);
        setFeature (GeneratorFeature.ALLOW_ICON_UPSCALE, true);
        setFeature (GeneratorFeature.PROCESS_GSTREAMER, true);

        // apply vendor feature settings
        if ("Features" in root.object) {
            auto featuresObj = root["Features"].object;
            foreach (featureId; featuresObj.byKey ()) {
                switch (featureId) {
                    case "validateMetainfo":
                        setFeature (GeneratorFeature.VALIDATE, featuresObj[featureId].type == JSON_TYPE.TRUE);
                        break;
                    case "processDesktop":
                        setFeature (GeneratorFeature.PROCESS_DESKTOP, featuresObj[featureId].type == JSON_TYPE.TRUE);
                        break;
                    case "noDownloads":
                            setFeature (GeneratorFeature.NO_DOWNLOADS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "createScreenshotsStore":
                            setFeature (GeneratorFeature.STORE_SCREENSHOTS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "optimizePNGSize":
                            setFeature (GeneratorFeature.OPTIPNG, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "metadataTimestamps":
                            setFeature (GeneratorFeature.METADATA_TIMESTAMPS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "immutableSuites":
                            setFeature (GeneratorFeature.METADATA_TIMESTAMPS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "processFonts":
                            setFeature (GeneratorFeature.PROCESS_FONTS, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "allowIconUpscaling":
                            setFeature (GeneratorFeature.ALLOW_ICON_UPSCALE, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    case "processGStreamer":
                            setFeature (GeneratorFeature.PROCESS_GSTREAMER, featuresObj[featureId].type == JSON_TYPE.TRUE);
                            break;
                    default:
                        break;
                }
            }
        }

        // check if we need to disable features because some prerequisites are not met
        if (featureEnabled (GeneratorFeature.OPTIPNG)) {
            if (!"/usr/bin/optipng".exists) {
                setFeature (GeneratorFeature.OPTIPNG, false);
                logError ("Disabled feature `optimizePNGSize`: The `optipng` binary was not found.");
            }
        }

        if (featureEnabled (GeneratorFeature.NO_DOWNLOADS)) {
            // since disallowing network access might have quite a lot of sideeffects, we print
            // a message to the logs to make debugging easier.
            // in general, running with noDownloads is discouraged.
            logWarning ("Configuration does not permit downloading files. Several features will not be available.");
        }

        if (!featureEnabled (GeneratorFeature.IMMUTABLE_SUITES)) {
            // Immutable suites won't work if the feature is disabled - log this error
            if (hasImmutableSuites)
                logError ("Suites are defined as immutable, but the `immutableSuites` feature is disabled. Immutability will not work!");
        }
    }

    bool isValid ()
    {
        return this.projectName != null;
    }

    /**
     * Get unique temporary directory to use during one generator run.
     */
    string getTmpDir ()
    {
        if (tmpDir.empty) {
            synchronized (this) {
                string root;
                if (cacheRootDir.empty)
                    root = "/tmp/";
                else
                    root = cacheRootDir;

                tmpDir = buildPath (root, "tmp", format ("asgen-%s", randomString (8)));
            }
        }

        return tmpDir;
    }
}
