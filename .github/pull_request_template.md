## Summary

Describe the operator-visible change and why it belongs in Bridge.

## Architecture checklist

- [ ] Bridge remains application-neutral.
- [ ] Proxy origins remain restricted to host loopback.
- [ ] Hostname ownership cannot be silently overwritten.
- [ ] NGINX configuration is validated before reload.
- [ ] Failure paths preserve or restore the previous working route state.
- [ ] Linux and Windows behavior remain aligned where applicable.

## Validation

- [ ] `npm test`
- [ ] Shell/PowerShell syntax validation
- [ ] Relevant integration or manual test
- [ ] Documentation updated for operator-visible changes

## Notes

Add migration details, screenshots/logs, compatibility notes or follow-up work here.
