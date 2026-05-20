package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// manifestImage is one entry under `images:` in sandboxctl.yaml.
type manifestImage struct {
	Name       string   `yaml:"name"`
	Context    string   `yaml:"context"`
	Dockerfile string   `yaml:"dockerfile,omitempty"`
	Tag        string   `yaml:"tag,omitempty"`
	Aliases    []string `yaml:"aliases,omitempty"`
	DependsOn  []string `yaml:"depends_on,omitempty"`
}

type buildManifest struct {
	Images []manifestImage `yaml:"images"`
}

// runParseBuildManifest is invoked as `sandboxctl _parse-build-manifest <path>`
// — a hidden subcommand consumed by sandbox.sh's cmd_build_from_manifest.
// Emits one tab-separated line per image:
//
//	name<TAB>context<TAB>dockerfile<TAB>tag<TAB>aliases-comma-sep<TAB>deps-comma-sep
//
// Replaces the previous bash+python regex parser, which broke on common
// YAML constructs (block scalars, nested arrays, comments mid-line).
//
// Also runs the same FROM-based cross-reference inference that
// _autogen-manifest does, so a hand-edited or pre-existing manifest
// transparently picks up missing aliases / depends_on. Manual entries
// are preserved; inference only adds, never removes.
func runParseBuildManifest(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _parse-build-manifest <path>")
		return 2
	}
	path, err := filepath.Abs(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "_parse-build-manifest: resolve %s: %v\n", args[0], err)
		return 1
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_parse-build-manifest: read %s: %v\n", path, err)
		return 1
	}
	var m buildManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		fmt.Fprintf(os.Stderr, "_parse-build-manifest: parse %s: %v\n", path, err)
		return 1
	}
	if len(m.Images) == 0 {
		fmt.Fprintf(os.Stderr, "_parse-build-manifest: no images in %s\n", path)
		return 1
	}
	// Default empty context/dockerfile/tag once, up-front, so the
	// inference pass and the emitted output agree on Dockerfile paths.
	for i := range m.Images {
		if m.Images[i].Name == "" {
			fmt.Fprintln(os.Stderr, "_parse-build-manifest: image entry missing 'name'")
			return 1
		}
		if m.Images[i].Context == "" {
			m.Images[i].Context = "."
		}
		if m.Images[i].Dockerfile == "" {
			m.Images[i].Dockerfile = filepath.ToSlash(filepath.Join(m.Images[i].Context, "Dockerfile"))
		}
		if m.Images[i].Tag == "" {
			m.Images[i].Tag = "latest"
		}
	}

	// Resolve absolute Dockerfile paths so resolveCrossRefs can read them.
	manifestDir := filepath.Dir(path)
	dfPaths := make([]string, len(m.Images))
	for i, img := range m.Images {
		df := img.Dockerfile
		if !filepath.IsAbs(df) {
			df = filepath.Join(manifestDir, df)
		}
		dfPaths[i] = df
	}

	imgs, warnings := resolveCrossRefs(m.Images, dfPaths, filepath.Base(manifestDir))
	imgs, sortWarn := topoSortImages(imgs)
	warnings = append(warnings, sortWarn...)
	for _, w := range warnings {
		fmt.Fprintf(os.Stderr, "_parse-build-manifest: %s\n", w)
	}

	for _, img := range imgs {
		fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\n",
			img.Name,
			img.Context,
			img.Dockerfile,
			img.Tag,
			strings.Join(img.Aliases, ","),
			strings.Join(img.DependsOn, ","),
		)
	}
	return 0
}
