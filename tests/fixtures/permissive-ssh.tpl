{{- /* TEST FIXTURE ONLY (tests/ac/05-no-admin.sh). Signs whatever principals the
       request names, to show the step-ca policy blocks a broken template. */ -}}
{
  "type": "user",
  "keyId": {{ toJson .KeyID }},
  "principals": {{ toJson .Principals }},
  "extensions": {"permit-pty": ""},
  "criticalOptions": {}
}
