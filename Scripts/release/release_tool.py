#!/usr/bin/env python3
"""Release helpers for ccemaphore's CI (Scripts/release/*.sh). Standard library only.

It runs unchanged on the macOS release runner, the Ubuntu preflight / verify-live runners and a
maintainer's Mac, so nothing here may depend on Xcode tools (no plutil, PlistBuddy or codesign).
The shell scripts call it as `python3 -I release_tool.py <subcommand> ...`.

Subcommands (results on stdout, diagnostics on stderr, any failure exits 1):
  pbxproj-setting <project.pbxproj> <SETTING> [--target NAME]
      The setting's effective value for the app target, resolved like Xcode does (the target level
      wins over the project level); every build configuration must agree on it.
  package-pin <project.pbxproj> <Package.resolved> <identity>
      The version Package.resolved pins; the project must require exactly that version.
  changelog-section <CHANGELOG.md> <version> [<fallback-version> ...]
      The body of the first matching "## [<version>]" section.
  plist-get <file.plist> <key>
  random-seed                         A fresh Ed25519 private seed, base64 (Sparkle's key-file format).
  ed25519-public-key                  stdin: a Sparkle private key (base64) -> its SUPublicEDKey.
  ed25519-check-public-key <base64>   Is this a usable SUPublicEDKey?
  feed-summary <appcast.xml>          key=value lines: items, max_build, max_short_version, signed.
  feed-item <appcast.xml> <build> <field>     One field of that build's item (url, length,
                                      ed_signature, short_version, minimum_system_version).
  feed-set-ed-signature <appcast.xml> <build> <base64>
      Key rotation only (make-appcast.sh --signing-pubkey): adds sparkle:edSignature to that build's
      unsigned enclosure and drops the feed signature, which must then be made again (sign_update).
  version-compare <a> <b>             -1 / 0 / 1 for dotted numeric versions.
  json-get <key>                      stdin: a JSON object (e.g. notarytool output) -> one value.
  verify-feed --feed F --pubkey K --build N --short-version V --min-os M [--url U] [--dmg D]
              [--notes N] [--feed-signature-only]
      Everything a Sparkle client with SURequireSignedFeed + SUPublicEDKey would check, plus our own
      release invariants. See verify_feed() below.
"""

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SP = "{%s}" % SPARKLE_NS
# generate_appcast appends this block after the XML (common_cli/Signing.swift signAppcast); Sparkle
# verifies the bytes before it (Sparkle/SPUExtractSignedFeed.m).
FEED_SIGNATURE_PREFIX = b"<!-- sparkle-signatures:\n"
PUBKEY_PLACEHOLDER = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"


class Failure(Exception):
    pass


def fail(message):
    raise Failure(message)


def warn(message):
    print("warning: " + message, file=sys.stderr)


# MARK: - Ed25519 (RFC 8032), verification and public-key derivation only
#
# Sparkle signs with orlp/ed25519, which is plain RFC 8032 Ed25519, so a signature that verifies here
# verifies in Sparkle. This lets CI check signatures against SUPublicEDKey itself, i.e. exactly what
# installed apps will do, without holding the private key (verify-live has no secrets) and without
# trusting that generate_appcast picked the right key. The selftest cross-checks it against Sparkle's
# own tools in both directions (keys it derives are accepted by generate_appcast; signatures
# generate_appcast makes verify here; wrong keys and tampered bytes are rejected).

_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _point_add(p, q):
    # Extended twisted Edwards coordinates (X, Y, Z, T), a = -1 (RFC 8032 section 5.1.4).
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = 2 * t1 * t2 * _D % _P
    d = 2 * z1 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _scalar_mult(s, p):
    q = (0, 1, 1, 0)  # the neutral element
    while s > 0:
        if s & 1:
            q = _point_add(q, p)
        p = _point_add(p, p)
        s >>= 1
    return q


def _points_equal(p, q):
    x1, y1, z1, _ = p
    x2, y2, z2, _ = q
    return (x1 * z2 - x2 * z1) % _P == 0 and (y1 * z2 - y2 * z1) % _P == 0


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


_GY = 4 * pow(5, _P - 2, _P) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _compress(p):
    x, y, z, _ = p
    zi = pow(z, _P - 2, _P)
    x, y = x * zi % _P, y * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


def ed25519_public_key(seed):
    digest = hashlib.sha512(seed).digest()
    a = int.from_bytes(digest[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return _compress(_scalar_mult(a, _G))


def ed25519_verify(public_key, message_chunks, signature):
    """message_chunks: an iterable of bytes, so a whole DMG never has to sit in memory."""
    if len(public_key) != 32 or len(signature) != 64:
        return False
    a_point = _decompress(public_key)
    r_point = _decompress(signature[:32])
    if a_point is None or r_point is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = hashlib.sha512()
    h.update(signature[:32])
    h.update(public_key)
    for chunk in message_chunks:
        h.update(chunk)
    k = int.from_bytes(h.digest(), "little") % _L
    return _points_equal(_scalar_mult(s, _G), _point_add(r_point, _scalar_mult(k, a_point)))


def _b64decode(text, what):
    try:
        return base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        fail("%s is not valid base64" % what)


def _signature_bytes(text):
    """A base64 signature from a feed; b"" (which never verifies) if it does not decode."""
    try:
        return base64.b64decode("".join((text or "").split()), validate=True)
    except (binascii.Error, ValueError):
        return b""


def decode_public_key(text):
    """A usable SUPublicEDKey: base64 of 32 bytes that decode to a point on the curve."""
    text = (text or "").strip()
    if not text or text == PUBKEY_PLACEHOLDER:
        fail("SUPublicEDKey is still the placeholder %r - generate the EdDSA key pair and put the "
             "public key into Resources/Info.plist (docs/RELEASING.md)" % PUBKEY_PLACEHOLDER)
    raw = _b64decode(text, "SUPublicEDKey")
    if len(raw) != 32:
        fail("SUPublicEDKey decodes to %d bytes; an Ed25519 public key is 32" % len(raw))
    if _decompress(raw) is None:
        fail("SUPublicEDKey is not a valid Ed25519 public key (not a curve point)")
    return raw


def public_key_from_private(text):
    """Sparkle's private key file: base64 of the 32-byte seed (generate_keys >= 2.x), or the older
    96-byte private+public format (common_cli/Secret.swift)."""
    raw = _b64decode(text, "the EdDSA private key")
    if len(raw) == 32:
        return ed25519_public_key(raw)
    if len(raw) == 96:
        return raw[64:]
    fail("the EdDSA private key decodes to %d bytes; expected 32 (seed) or 96 (old format)" % len(raw))


# MARK: - project.pbxproj


_OBJECT_RE = re.compile(r"^\t\t([0-9A-F]{24})(?: /\*.*?\*/)? = \{\n(.*?)^\t\t\};$", re.M | re.S)
_ID_RE = re.compile(r"[0-9A-F]{24}")


def _pbx_objects(text):
    return {m.group(1): m.group(2) for m in _OBJECT_RE.finditer(text)}


def _pbx_field(body, name):
    m = re.search(r"^\t\t\t%s = (.*?);$" % re.escape(name), body, re.M)
    return _pbx_unquote(m.group(1)) if m else None


def _pbx_unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return value


def _pbx_build_settings(body):
    m = re.search(r"^\t\t\tbuildSettings = \{\n(.*?)^\t\t\t\};$", body, re.M | re.S)
    settings = {}
    if m:
        for line in m.group(1).splitlines():
            sm = re.match(r"^\t\t\t\t([A-Za-z0-9_\[\]=*,. -]+?) = (.*);$", line)
            if sm:
                settings[sm.group(1)] = _pbx_unquote(sm.group(2))
    return settings


def _pbx_config_list(objects, list_id):
    body = objects.get(list_id)
    if body is None:
        fail("project.pbxproj: configuration list %s not found" % list_id)
    m = re.search(r"buildConfigurations = \((.*?)\);", body, re.S)
    configs = {}
    for config_id in _ID_RE.findall(m.group(1) if m else ""):
        config = objects.get(config_id)
        if config is None:
            fail("project.pbxproj: build configuration %s not found" % config_id)
        if "baseConfigurationReference" in config:
            fail("project.pbxproj: build configuration %s uses an .xcconfig file; the release scripts "
                 "only read settings written in the project itself" % config_id)
        configs[_pbx_field(config, "name")] = _pbx_build_settings(config)
    return configs


def pbxproj_setting(path, setting, target):
    with open(path, encoding="utf-8") as f:
        objects = _pbx_objects(f.read())
    project_list = target_list = None
    for body in objects.values():
        isa = _pbx_field(body, "isa")
        if isa == "PBXProject":
            project_list = _ID_RE.search(_pbx_field(body, "buildConfigurationList") or "")
        elif isa == "PBXNativeTarget" and _pbx_field(body, "name") == target:
            target_list = _ID_RE.search(_pbx_field(body, "buildConfigurationList") or "")
    if project_list is None or target_list is None:
        fail("project.pbxproj: could not find the project or the %r target" % target)
    project_configs = _pbx_config_list(objects, project_list.group(0))
    target_configs = _pbx_config_list(objects, target_list.group(0))

    effective = {}
    for name, settings in sorted(target_configs.items()):
        project_value = project_configs.get(name, {}).get(setting)
        value = settings.get(setting, project_value)
        if value is None:
            fail("%s is not set for the %s configuration" % (setting, name))
        if "$" in value:
            fail("%s = %r in %s refers to another setting; use a literal value" % (setting, value, name))
        if setting in settings and project_value is not None and project_value != value:
            warn("%s: the target's %s value %r hides the project-level %r (harmless, but keep one place)"
                 % (setting, name, value, project_value))
        effective[name] = value
    if len(set(effective.values())) != 1:
        fail("%s differs between build configurations: %s - set one value for all of them"
             % (setting, ", ".join("%s=%s" % kv for kv in sorted(effective.items()))))
    return next(iter(effective.values()))


def package_pin(pbxproj_path, resolved_path, identity):
    with open(pbxproj_path, encoding="utf-8") as f:
        objects = _pbx_objects(f.read())
    required = None
    for body in objects.values():
        if _pbx_field(body, "isa") != "XCRemoteSwiftPackageReference":
            continue
        url = _pbx_field(body, "repositoryURL") or ""
        if re.sub(r"\.git$", "", url.rstrip("/").rsplit("/", 1)[-1]).lower() != identity:
            continue
        kind = re.search(r"\bkind = (\w+);", body)
        version = re.search(r"\bversion = ([^;]+);", body)
        if not kind or kind.group(1) != "exactVersion" or not version:
            fail("the project must pin package %r with an exact version (Xcode: Dependency Rule "
                 "'Exact Version')" % identity)
        required = _pbx_unquote(version.group(1))
    if required is None:
        fail("project.pbxproj has no package reference for %r" % identity)
    try:
        with open(resolved_path, encoding="utf-8") as f:
            resolved = json.load(f)
    except FileNotFoundError:
        fail("%s is missing - commit it, the release build only uses the versions it pins" % resolved_path)
    pins = [p for p in resolved.get("pins", []) if p.get("identity") == identity]
    if len(pins) != 1:
        fail("%s does not pin %r" % (resolved_path, identity))
    pinned = (pins[0].get("state") or {}).get("version")
    if pinned != required:
        fail("Package.resolved pins %s %s but the project requires exactly %s - resolve packages in "
             "Xcode and commit Package.resolved" % (identity, pinned, required))
    return pinned


# MARK: - CHANGELOG.md


def changelog_section(path, versions):
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for version in versions:
        heading = re.compile(r"^## \[%s\](?:\s|$)" % re.escape(version))
        for i, line in enumerate(lines):
            if not heading.match(line):
                continue
            body = []
            for following in lines[i + 1:]:
                # The section ends at the next "## " heading or at the link reference definitions.
                if following.startswith("## ") or re.match(r"^\[[^\]]+\]:\s*\S", following):
                    break
                body.append(following)
            text = "\n".join(body).strip("\n")
            if not text.strip():
                fail("CHANGELOG.md: the '## [%s]' section is empty" % version)
            return text + "\n"
    fail("CHANGELOG.md has no '## [%s]' section" % "]' or '## [".join(versions))


# MARK: - Appcast feeds


def version_key(version):
    parts = version.strip().split(".")
    if not all(p.isdigit() for p in parts):
        fail("not a dotted numeric version: %r" % version)
    return tuple(int(p) for p in parts)


def compare_versions(a, b):
    ka, kb = version_key(a), version_key(b)
    width = max(len(ka), len(kb))
    ka, kb = ka + (0,) * (width - len(ka)), kb + (0,) * (width - len(kb))
    return (ka > kb) - (ka < kb)


def split_feed_signature(data):
    """Mirror of SPUExtractAppcastContent: (signed content, base64 signature or None, length or None)."""
    start = data.rfind(FEED_SIGNATURE_PREFIX)
    if start < 0:
        return data, None, None
    end = data.find(b"-->", start + len(FEED_SIGNATURE_PREFIX))
    if end < 0:
        return data, None, None
    signature = length = None
    for line in data[start + len(FEED_SIGNATURE_PREFIX):end].decode("utf-8", "replace").splitlines():
        if line.startswith("edSignature:"):
            signature = line[len("edSignature:"):].strip()
        elif line.startswith("length:"):
            try:
                length = int(line[len("length:"):].strip())
            except ValueError:
                length = -1
    return data[:start], signature, length


def _text(element, tag):
    found = element.find(tag)
    return found.text.strip() if found is not None and found.text else None


class FeedItem:
    def __init__(self, element):
        enclosure = element.find("enclosure")
        self.enclosure = enclosure
        attributes = enclosure.attrib if enclosure is not None else {}
        self.build = _text(element, SP + "version") or attributes.get(SP + "version")
        self.short_version = _text(element, SP + "shortVersionString") or attributes.get(SP + "shortVersionString")
        self.minimum_system_version = _text(element, SP + "minimumSystemVersion")
        self.hardware_requirements = _text(element, SP + "hardwareRequirements")
        self.url = attributes.get("url")
        self.length = attributes.get("length")
        self.ed_signature = attributes.get(SP + "edSignature")
        description = element.find("description")
        self.notes = description.text if description is not None else None
        self.notes_format = description.get(SP + "format") if description is not None else None


def parse_feed(path):
    with open(path, "rb") as f:
        data = f.read()
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        fail("%s contains a DTD - refusing to parse it" % path)
    content, signature, length = split_feed_signature(data)
    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        fail("%s is not well-formed XML: %s" % (path, error))
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        fail("%s is not an RSS feed with a <channel>" % path)
    items = [FeedItem(element) for element in channel.findall("item")]
    for item in items:
        if not item.build:
            fail("%s has an item without sparkle:version" % path)
    return content, signature, length, items


def feed_summary(path):
    _, signature, _, items = parse_feed(path)
    max_build = max_short = None
    for item in items:
        if max_build is None or compare_versions(item.build, max_build) > 0:
            max_build = item.build
        if item.short_version and (max_short is None or compare_versions(item.short_version, max_short) > 0):
            max_short = item.short_version
    return [
        ("items", str(len(items))),
        ("max_build", max_build or ""),
        ("max_short_version", max_short or ""),
        ("builds", ",".join(item.build for item in items)),
        ("signed", "true" if signature else "false"),
    ]


def feed_set_ed_signature(path, build, signature):
    """Key rotation (make-appcast.sh --signing-pubkey): generate_appcast signs the feed with the key the
    installed copies trust, but leaves the new item unsigned because its app carries the NEW key. Add the
    item's signature (made with sign_update and the same key) as a plain text edit - nothing else in the
    feed changes - and drop the now stale feed signature block, so the file has to be signed again."""
    if len(_signature_bytes(signature)) != 64:
        fail("%r is not an EdDSA signature (base64 of 64 bytes)" % signature)
    with open(path, "rb") as f:
        content, _, _ = split_feed_signature(f.read())
    text = content.decode("utf-8")
    namespace = re.search(r'xmlns:([A-Za-z_][\w.-]*)\s*=\s*"%s"' % re.escape(SPARKLE_NS), text)
    if not namespace:
        fail("%s does not declare the Sparkle namespace" % path)
    prefix = re.escape(namespace.group(1))

    # Mask CDATA sections (the embedded release notes) and comments, so their text is never taken for
    # markup; NUL cannot occur in XML, so the placeholders are unambiguous.
    hidden = []

    def hide(match):
        hidden.append(match.group(0))
        return "\0%d\0" % (len(hidden) - 1)

    masked = re.sub(r"<!\[CDATA\[.*?\]\]>|<!--.*?-->", hide, text, flags=re.S)
    version = re.compile(r"<%s:version>\s*%s\s*</%s:version>|\b%s:version\s*=\s*\"%s\""
                         % (prefix, re.escape(build), prefix, prefix, re.escape(build)))
    items = [m for m in re.finditer(r"<item\b.*?</item>", masked, re.S) if version.search(m.group(0))]
    if len(items) != 1:
        fail("%s has %d items for build %s" % (path, len(items), build))
    item = items[0]
    enclosures = list(re.finditer(r"<enclosure\b[^>]*>", item.group(0)))
    if len(enclosures) != 1:
        fail("build %s has %d enclosures" % (build, len(enclosures)))
    tag = enclosures[0].group(0)
    if re.search(r"\b%s:edSignature\s*=" % prefix, tag):
        fail("build %s is already signed" % build)
    close = "/>" if tag.endswith("/>") else ">"
    signed = "%s %s:edSignature=\"%s\"%s" % (tag[:-len(close)].rstrip(), namespace.group(1), signature, close)
    start = item.start() + enclosures[0].start()
    masked = masked[:start] + signed + masked[start + len(tag):]
    text = re.sub(r"\0(\d+)\0", lambda m: hidden[int(m.group(1))], masked)

    with open(path + ".tmp", "wb") as f:
        f.write(text.encode("utf-8"))
    os.replace(path + ".tmp", path)
    found = [i for i in parse_feed(path)[3] if i.build == build]
    if len(found) != 1 or found[0].ed_signature != signature:
        fail("%s: the signature did not end up on build %s" % (path, build))


def _file_chunks(path, size=1 << 20):
    with open(path, "rb") as f:
        while True:
            chunk = f.read(size)
            if not chunk:
                return
            yield chunk


def verify_feed(args):
    """The release gate for a generated (or live) appcast. Fails unless all of these hold:

    - the feed is signed (SURequireSignedFeed) and the signature verifies against SUPublicEDKey,
      over exactly the bytes Sparkle checks, with the recorded length;
    - every item has an absolute https enclosure URL, a length and an EdDSA signature;
    - exactly one item has sparkle:version == --build, and it is the newest item in the feed;
    - that item's shortVersionString, minimumSystemVersion, URL and notes are the expected ones and it
      carries no hardware requirement (ccemaphore ships universal);
    - with --dmg: the enclosure length is the DMG's size and its EdDSA signature verifies over the DMG.
    generate_appcast exits 0 even when it could not sign (key mismatch), so this is what catches it.
    """
    public_key = decode_public_key(args.pubkey)
    content, signature, signed_length, items = parse_feed(args.feed)
    problems = []

    if signature is None:
        problems.append("the feed has no sparkle-signatures block (apps with SURequireSignedFeed reject it)")
    else:
        if signed_length != len(content):
            problems.append("the feed signature covers %s bytes but the content is %d bytes"
                            % (signed_length, len(content)))
        if not ed25519_verify(public_key, [content], _signature_bytes(signature)):
            problems.append("the feed signature does not verify against SUPublicEDKey")

    if args.feed_signature_only:
        return problems, None

    for item in items:
        if not item.url or not item.url.startswith("https://"):
            problems.append("item %s: enclosure URL %r is not an absolute https URL" % (item.build, item.url))
        if not item.length or not item.length.isdigit():
            problems.append("item %s: enclosure has no valid length" % item.build)
        if not item.ed_signature:
            problems.append("item %s: enclosure has no sparkle:edSignature (SUPublicEDKey / private key "
                            "mismatch at generate_appcast time?)" % item.build)

    matches = [item for item in items if item.build == args.build]
    if len(matches) != 1:
        problems.append("expected exactly one item with sparkle:version %s, found %d (builds in feed: %s)"
                        % (args.build, len(matches), ", ".join(i.build for i in items) or "none"))
        return problems, None
    item = matches[0]
    newer = [i.build for i in items if compare_versions(i.build, args.build) > 0]
    if newer:
        problems.append("build %s is not the newest item; the feed also has %s" % (args.build, ", ".join(newer)))
    if item.short_version != args.short_version:
        problems.append("shortVersionString is %r, expected %r" % (item.short_version, args.short_version))
    if item.minimum_system_version != args.min_os:
        problems.append("minimumSystemVersion is %r, expected %r" % (item.minimum_system_version, args.min_os))
    if item.hardware_requirements:
        problems.append("the item requires hardware %r - the app must be built universal (arm64 + x86_64)"
                        % item.hardware_requirements)
    if args.url and item.url != args.url:
        problems.append("enclosure URL is %r, expected %r" % (item.url, args.url))
    if args.notes is not None:
        with open(args.notes, encoding="utf-8") as f:
            expected_notes = f.read().strip()
        if item.notes_format != "markdown" or (item.notes or "").strip() != expected_notes:
            problems.append("the embedded release notes are missing or differ from %s" % args.notes)
    if args.dmg:
        size = os.path.getsize(args.dmg)
        if item.length != str(size):
            problems.append("enclosure length is %s but %s is %d bytes" % (item.length, args.dmg, size))
        if item.ed_signature:
            if not ed25519_verify(public_key, _file_chunks(args.dmg), _signature_bytes(item.ed_signature)):
                problems.append("the enclosure's EdDSA signature does not verify over %s against SUPublicEDKey"
                                % args.dmg)
    return problems, item


# MARK: - CLI


def main(argv):
    parser = argparse.ArgumentParser(prog="release_tool.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pbxproj-setting")
    p.add_argument("pbxproj")
    p.add_argument("setting")
    p.add_argument("--target", default="ccemaphore")

    p = sub.add_parser("package-pin")
    p.add_argument("pbxproj")
    p.add_argument("resolved")
    p.add_argument("identity")

    p = sub.add_parser("changelog-section")
    p.add_argument("changelog")
    p.add_argument("versions", nargs="+")

    p = sub.add_parser("plist-get")
    p.add_argument("plist")
    p.add_argument("key")

    sub.add_parser("random-seed")
    sub.add_parser("ed25519-public-key")
    p = sub.add_parser("ed25519-check-public-key")
    p.add_argument("pubkey")

    p = sub.add_parser("feed-summary")
    p.add_argument("feed")

    p = sub.add_parser("feed-item")
    p.add_argument("feed")
    p.add_argument("build")
    p.add_argument("field", choices=["url", "length", "ed_signature", "short_version", "minimum_system_version"])

    p = sub.add_parser("feed-set-ed-signature")
    p.add_argument("feed")
    p.add_argument("build")
    p.add_argument("signature")

    p = sub.add_parser("version-compare")
    p.add_argument("a")
    p.add_argument("b")

    p = sub.add_parser("json-get")
    p.add_argument("key")

    p = sub.add_parser("verify-feed")
    p.add_argument("--feed", required=True)
    p.add_argument("--pubkey", required=True)
    p.add_argument("--build")
    p.add_argument("--short-version")
    p.add_argument("--min-os")
    p.add_argument("--url")
    p.add_argument("--dmg")
    p.add_argument("--notes")
    p.add_argument("--feed-signature-only", action="store_true",
                   help="only check the feed signature (for feeds we did not just generate)")

    args = parser.parse_args(argv)
    try:
        if args.command == "pbxproj-setting":
            print(pbxproj_setting(args.pbxproj, args.setting, args.target))
        elif args.command == "package-pin":
            print(package_pin(args.pbxproj, args.resolved, args.identity))
        elif args.command == "changelog-section":
            sys.stdout.write(changelog_section(args.changelog, args.versions))
        elif args.command == "plist-get":
            with open(args.plist, "rb") as f:
                plist = plistlib.load(f)
            if args.key not in plist:
                fail("%s has no %s" % (args.plist, args.key))
            value = plist[args.key]
            print(("true" if value else "false") if isinstance(value, bool) else value)
        elif args.command == "random-seed":
            print(base64.b64encode(os.urandom(32)).decode())
        elif args.command == "ed25519-public-key":
            print(base64.b64encode(public_key_from_private(sys.stdin.read())).decode())
        elif args.command == "ed25519-check-public-key":
            decode_public_key(args.pubkey)
        elif args.command == "feed-summary":
            for key, value in feed_summary(args.feed):
                print("%s=%s" % (key, value))
        elif args.command == "feed-item":
            matches = [item for item in parse_feed(args.feed)[3] if item.build == args.build]
            if len(matches) != 1:
                fail("%s has %d items for build %s" % (args.feed, len(matches), args.build))
            value = getattr(matches[0], args.field)
            if not value:
                fail("%s: build %s has no %s" % (args.feed, args.build, args.field))
            print(value)
        elif args.command == "feed-set-ed-signature":
            feed_set_ed_signature(args.feed, args.build, args.signature.strip())
        elif args.command == "version-compare":
            print(compare_versions(args.a, args.b))
        elif args.command == "json-get":
            try:
                document = json.load(sys.stdin)
            except ValueError:
                fail("stdin is not JSON")
            value = document.get(args.key) if isinstance(document, dict) else None
            if value is None:
                fail("no %r in the JSON document" % args.key)
            print(value)
        elif args.command == "verify-feed":
            if not args.feed_signature_only and not (args.build and args.short_version and args.min_os):
                parser.error("verify-feed needs --build, --short-version and --min-os")
            problems, item = verify_feed(args)
            if problems:
                for problem in problems:
                    print("  - " + problem, file=sys.stderr)
                fail("%s failed verification (%d problem%s)"
                     % (args.feed, len(problems), "" if len(problems) == 1 else "s"))
            if item is not None:
                print("ok: %s build %s (%s) -> %s, %s bytes, EdDSA-signed; feed signature valid"
                      % (args.feed, item.build, item.short_version, item.url, item.length))
            else:
                print("ok: %s feed signature valid" % args.feed)
    except Failure as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
