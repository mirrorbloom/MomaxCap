# spatial_data_recorder

A new Flutter project.

## Upload Environment Config

Upload settings are read from `.env` at runtime. The app no longer hardcodes
backend URL or auth token.

1. Copy `.env-example` to `.env`.
2. Update `UPLOAD_BASE_URL` and `UPLOAD_AUTH_TOKEN`.
3. Ensure backend `AUTH_TOKENS` uses the same token value.

If `UPLOAD_BASE_URL` uses an IPv6 literal, wrap host with brackets:

- `http://[240e:3bb:2e71:310::1101]:8080`

Required keys:

- `UPLOAD_BASE_URL`
- `UPLOAD_PATH`
- `UPLOAD_AUTH_TOKEN`

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
