package main

import (
	"fmt"
	"os"
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
func runParseBuildManifest(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _parse-build-manifest <path>")
		return 2
	}
	path := args[0]
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
	for _, img := range m.Images {
		if img.Name == "" {
			fmt.Fprintln(os.Stderr, "_parse-build-manifest: image entry missing 'name'")
			return 1
		}
		ctx := img.Context
		if ctx == "" {
			ctx = "."
		}
		df := img.Dockerfile
		if df == "" {
			df = ctx + "/Dockerfile"
		}
		tag := img.Tag
		if tag == "" {
			tag = "latest"
		}
		fmt.Printf("%s\t%s\t%s\t%s\t%s\t%s\n",
			img.Name,
			ctx,
			df,
			tag,
			strings.Join(img.Aliases, ","),
			strings.Join(img.DependsOn, ","),
		)
	}
	return 0
}
