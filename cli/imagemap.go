package main

// Image-name resolution: the generators (chart values, umbrella values,
// Kargo Warehouse) must reference the image coordinates `sandboxctl
// build` will actually push — not assume image name == app name. Build
// pushes what sandboxctl.yaml's images: list says (or, without a
// manifest, what the autogen derivation computes), so this maps each
// detected app to that truth. A wrong assumption here is invisible
// until the pod says ImagePullBackOff: the chart asks the sandbox
// registry for <app>:latest while build pushed <manifest-name>:<tag>.

import (
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// appImage is the registry-relative repo name + tag build will push.
type appImage struct {
	Name string
	Tag  string
}

// resolveAppImages maps app name → the image build will push for it,
// using the same source of truth cmd_build uses: the sandboxctl.yaml
// manifest when present, the autogen Dockerfile derivation otherwise.
//
// Matching per app, first hit wins:
//  1. name  — slugified image name equals the app name
//  2. prefixed name — image name is <project>-<app> (manifests often
//     namespace images by repo, e.g. agent-observability-agent-sim)
//  3. dockerfile — the image builds the app's own Dockerfile
//  4. context    — exactly one image's build context is the app's dir
//  5. sole  — one image, one app: they belong together
//
// Apps with no confident match are absent from the map — the
// generators then fall back to <app>:latest (today's behaviour), and
// scaffold warns so the gap is visible at generation time, not at
// ImagePullBackOff time.
func resolveAppImages(root string, apps []reposcan.App) map[string]appImage {
	imgs := loadBuildImages(root)
	out := map[string]appImage{}
	if len(imgs) == 0 {
		return out
	}

	project := slugifyName(filepath.Base(root))
	for _, app := range apps {
		if ref, ok := matchAppImage(app, apps, imgs, project); ok {
			out[app.Name] = ref
		}
	}
	return out
}

func matchAppImage(app reposcan.App, apps []reposcan.App, imgs []manifestImage, project string) (appImage, bool) {
	appSlug := slugifyName(app.Name)

	// 1. name match — image named after the app.
	for _, img := range imgs {
		if slugifyName(img.Name) == appSlug {
			return refOf(img), true
		}
	}

	// 2. prefixed name — <project>-<app>, the common convention when a
	// manifest namespaces every image by the repo it came from.
	if project != "" {
		for _, img := range imgs {
			if slugifyName(img.Name) == project+"-"+appSlug {
				return refOf(img), true
			}
		}
	}

	// 3. dockerfile match — the image builds the app's own Dockerfile.
	if app.Dockerfile != "" {
		appDf := filepath.ToSlash(filepath.Clean(app.Dockerfile))
		for _, img := range imgs {
			if filepath.ToSlash(filepath.Clean(img.Dockerfile)) == appDf {
				return refOf(img), true
			}
		}
	}

	// 4. context match — exactly one image built from the app's dir.
	var ctxHits []manifestImage
	appDir := filepath.ToSlash(filepath.Clean(app.Path))
	for _, img := range imgs {
		if filepath.ToSlash(filepath.Clean(img.Context)) == appDir {
			ctxHits = append(ctxHits, img)
		}
	}
	if len(ctxHits) == 1 {
		return refOf(ctxHits[0]), true
	}

	// 5. sole image + sole app — they can only belong together.
	if len(imgs) == 1 && len(apps) == 1 {
		return refOf(imgs[0]), true
	}

	return appImage{}, false
}

func refOf(img manifestImage) appImage {
	tag := img.Tag
	if tag == "" {
		tag = "latest"
	}
	return appImage{Name: img.Name, Tag: tag}
}

// loadBuildImages returns the images cmd_build would push, normalized
// (context defaulted to ".", dockerfile to <context>/Dockerfile, tag to
// latest) — from the manifest when one exists, else the autogen
// derivation over the repo's Dockerfiles.
func loadBuildImages(root string) []manifestImage {
	for _, base := range []string{"sandboxctl.yaml", "sandboxctl.yml"} {
		data, err := os.ReadFile(filepath.Join(root, base))
		if err != nil {
			continue
		}
		var m buildManifest
		if yaml.Unmarshal(data, &m) != nil || len(m.Images) == 0 {
			// A manifest without images: (e.g. only apps:/secrets:
			// overrides) falls through to the autogen derivation —
			// exactly what cmd_build does.
			break
		}
		for i := range m.Images {
			if m.Images[i].Context == "" {
				m.Images[i].Context = "."
			}
			if m.Images[i].Dockerfile == "" {
				m.Images[i].Dockerfile = filepath.ToSlash(filepath.Join(m.Images[i].Context, "Dockerfile"))
			}
		}
		var withNames []manifestImage
		for _, img := range m.Images {
			if img.Name != "" {
				withNames = append(withNames, img)
			}
		}
		return withNames
	}

	dockerfiles, err := findDockerfiles(root)
	if err != nil || len(dockerfiles) == 0 {
		return nil
	}
	imgs, _ := buildAutogenImages(root, dockerfiles)
	return imgs
}

// hasBuildManifest reports whether the repo carries a sandboxctl.yaml
// with an images: list — the case where an app missing from it is a
// real gap worth warning about (autogen can't miss a Dockerfile'd app).
func hasBuildManifest(root string) bool {
	for _, base := range []string{"sandboxctl.yaml", "sandboxctl.yml"} {
		data, err := os.ReadFile(filepath.Join(root, base))
		if err != nil {
			continue
		}
		var m buildManifest
		if yaml.Unmarshal(data, &m) == nil && len(m.Images) > 0 {
			return true
		}
	}
	return false
}
