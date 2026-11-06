# Design QA — NotchClip

- Visual target: first compact-list concept selected by the user.
- Rendered evidence: `docs/images/history.jpg`, a native window screenshot using synthetic data at the compact 420 × 360 point setting. The reference was larger; density and proportions were compared at their respective intended sizes.
- Compared: toolbar, search, grouped filters, list density, typography, contrast, and row actions. The five filters and context menu replace the concept's extra code category and ellipsis, as requested subsequently. The screenshot contains no user clipboard data.
- Verified in the synthetic native preview: eight entries at medium size, list, full text preview, edit controls, context menu at the pointer, and settings at 420-point width. Final filter layout uses text-only chips when the icon version does not fit.
- Remaining manual verification: cross-application file drag and animation frame smoothness on a physical Mac. These are not covered by model-level tests.
- final result: passed for the reviewed compact layout; cross-application interaction and animation are separately unverified.
