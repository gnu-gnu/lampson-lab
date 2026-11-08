{{- /*
  x5c-spire SSH user certificate template (CONTRACT §5.2).

  Identity comes only from the verified X5C leaf (.AuthorizationCrt), never from
  the token subject or request body. .Mapping is templateData from
  step/ssh-mapping.json, written into ca.json by bootstrap.

  Every branch that does not match the mapping exactly ends in `fail`: there is
  no default and no fallback.
*/ -}}
{{- $crt := .AuthorizationCrt -}}
{{- if ne .Type "user" -}}
  {{- fail (printf "x5c-spire: only user certificates are issued, not %q" .Type) -}}
{{- end -}}
{{- if ne (len $crt.URIs) 1 -}}
  {{- fail "x5c-spire: the X5C leaf must carry exactly one URI SAN (a SPIFFE ID)" -}}
{{- end -}}
{{- $id := (index $crt.URIs 0).String -}}
{{- $m := get .Mapping $id -}}
{{- if not $m -}}
  {{- fail (printf "x5c-spire: %s has no SSH mapping" $id) -}}
{{- end -}}
{{- range $m.principals -}}
  {{- if hasPrefix "role-admin@" . -}}
    {{- fail (printf "x5c-spire: the mapping for %s lists %s; role-admin@* is never issued" $id .) -}}
  {{- end -}}
{{- end -}}
{{- if ne .KeyID $id -}}
  {{- fail (printf "x5c-spire: key id %q is not the SVID's SPIFFE ID %s" .KeyID $id) -}}
{{- end -}}
{{- range .Principals -}}
  {{- if hasPrefix "role-admin@" . -}}
    {{- fail (printf "x5c-spire: %s is never issued" .) -}}
  {{- end -}}
  {{- if not (has . $m.principals) -}}
    {{- fail (printf "x5c-spire: %s is not mapped for %s" . $id) -}}
  {{- end -}}
{{- end -}}
{{- /*
  TTL: step-ca already refuses a certificate that outlives the X5C leaf. Bounding
  the leaf's remaining lifetime by the identity's maxTTL therefore bounds the
  certificate too, whatever validity the request asks for (DECISIONS D-11).
*/ -}}
{{- $remaining := ($crt.NotAfter.Sub now).Seconds -}}
{{- if gt $remaining (float64 $m.maxTTL) -}}
  {{- fail (printf "x5c-spire: SVID for %s is valid for %.0fs, longer than its %vs limit" $id $remaining $m.maxTTL) -}}
{{- end -}}
{
  "type": "user",
  "keyId": {{ toJson $id }},
  "principals": {{ toJson $m.principals }},
  "extensions": {"permit-pty": ""},
  "criticalOptions": {}
}
