# Scipio

![GitHub](https://img.shields.io/github/license/evandcoleman/Scipio) ![GitHub release (latest by date)](https://img.shields.io/github/v/release/evandcoleman/Scipio) ![GitHub Workflow Status (branch)](https://img.shields.io/github/workflow/status/evandcoleman/Scipio/test/main) ![Code Climate maintainability](https://img.shields.io/codeclimate/maintainability/evandcoleman/Scipio)

`Scipio` is a tool that takes existing Swift packages, binary frameworks, or CocoaPods, compiles them into XCFrameworks and delivers them as a single Swift package.

**_The Problem_**: Each dependency manager has its own drawbacks and advantages. `CocoaPods` is incredibly easy to setup, but requires you to compile each dependency from source. This can add a significant amount of time to your builds if you have a lot of dependencies. `Carthage` solves this problem, but not every library supports it and it adds several steps to your build pipeline.

`Scipio` aims to solve these problems by leveraging the Swift package manager support built into Xcode 11+ along with SPM's ability to distribute binary frameworks.

## How it works

`Scipio` takes existing Swift packages, CocoaPods, and pre-built frameworks and generates a Swift package that uses pre-built frameworks stored locally or on a remote server (like S3).

### Supported Inputs

- Swift packages
- CocoaPods
- `.xcframework` via URL packaged as a `.zip` or `.tar.gz`

## Installation

### Homebrew (Recommended)

1. Ensure that you have `homebrew` installed. Visit [brew.sh](https://brew.sh) for more info.
2. Run `brew install evandcoleman/tap/scipio`

### Manually from Source

1. Clone the project and enter the directory

  ```bash
  $ git clone https://github.com/evandcoleman/Scipio.git
  $ cd Scipio
  ```

2. Run `make install`

## Usage

You have a few options for how to integrate Scipio into your project.

- **If you want to share dependencies between multiple users of your project(s) across many machines:**
	
	1. Create a new `git` repository somewhere on your machine.
	2. Add your `scipio.yml` file (see Configuration section below). Be sure to use a non-local cache engine (such as `http`).
	3. Run `scipio`.
	4. Once Scipio completes, you'll have a new `Package.swift` file. Push this file to the new repository and create a new release tag.
	5. Integrate the new package into your main project using the `git` URL for the new repository and specifying your release tag as the version.

- **If you want to share dependencies between multiple projects:**

	1. Create a new folder somewhere on your machine.
	2. Add your `scipio.yml` file (see Configuration section below). Be sure to use the `local` cache engine.
	3. Run `scipio`.
	4. Once Scipio completes, you'll have a new `Package.swift` file.
	5. Integrate the new package into your projects by dragging the containing directory into the Xcode project navigator.

- **If your use case doesn't fall into one of the buckets above, use the basic setup:**

	1. Create a new folder inside your project.
	2. Add your `scipio.yml` file (see Configuration section below). Be sure to use the `local` cache engine.
	3. Run `scipio`.
	4. Once Scipio completes, you'll have a new `Package.swift` file.
	5. Integrate the new package into your project by dragging the containing directory into the Xcode project navigator.

## Configuration

Configuration is managed via a [YAML](https://yaml.org) file, `scipio.yml`. By default, Scipio looks for this file in the current directory, but you can override this behavior by specifying the `--config` flag followed by a path to a directory containing a `scipio.yml` file.

It is recommended to create a separate repository to store your Scipio configuration. This is where the generated `Package.swift` will live.

### Top Level Keys

**`name`**: The name you want to use for the Swift package that Scipio generates. If you're using a local cache engine, this should be the name of the enclosing folder.

**`deploymentTarget`**: The deployment targets that you'd like to build dependencies for.

**`cache`**: The cache engine to use. Currently `http` (with a `url`) and `local` (with a `path`) are supported.

**`binaries`**: An array of binary frameworks to download and include. These must be `zip` or `tar.gz` archives that contain either xcframeworks or Universal frameworks.

**`packages`**: An array of Swift packages to build and include. See [here](https://github.com/evandcoleman/Scipio/blob/main/Sources/ScipioKit/Models/Dependency.swift#L56) for supported options.

**`pods`**: An array of CocoaPods to build and include. See [here](https://github.com/evandcoleman/Scipio/blob/main/Sources/ScipioKit/Models/Dependency.swift#L44) for supported options.

### Example

```yaml
name: MyAppCore

deploymentTarget:
  iOS: "12.0"

cache:
  http:
    url: https://<your-bucket-name>.s3.amazonaws.com/

binaries:
  - name: Facebook
    url: https://github.com/facebook/facebook-ios-sdk/releases/download/v9.1.0/FacebookSDK.xcframework.zip
    version: 9.1.0
  - name: Firebase
    url: https://github.com/firebase/firebase-ios-sdk/releases/download/8.6.0/Firebase.zip
    version: 8.6.0

packages:
  - name: SDWebImage
    url: https://github.com/SDWebImage/SDWebImage
    branch: 5.9.2
  - name: SnapKit
    url: https://github.com/SnapKit/SnapKit
    branch: 5.0.0

pods:
  - name: GoogleTagManager
    from: 7.4.0
    # We must exclude these dependencies of GoogleTagManager because they
    # are included in the `Firebase` binary package above.
    # Scipio will error if you omit this.
    excludes:
      - FBLPromises
      - FirebaseAnalytics
      - FirebaseCore
      - FirebaseCoreDiagnostics
      - FirebaseInstallations
      - GoogleAppMeasurement
      - GoogleDataTransport
      - GoogleUtilities
      - nanopb
  - name: IGListKit
    version: 4.0.0
```

## Development

Clone the project and open `Package.swift` in Xcode

```bash
$ git clone https://github.com/evandcoleman/Scipio.git
$ cd Scipio && open Package.swift
```

## License

Scipio is released under the [MIT License](LICENSE.md).
