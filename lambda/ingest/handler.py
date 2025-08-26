import os, json, time, gzip, base64
import boto3
from jsonschema import validate, ValidationError
from datetime import datetime, timezone

s3 = boto3.client("s3")
RAW_BUCKET = os.environ["RAW_BUCKET"]

with open(os.path.join(os.path.dirname(__file__), "schema.json")) as f:
    SCHEMA = json.load(f)

def resp(code, body): 
    return {"statusCode": code, "headers":{"Content-Type":"application/json"}, "body": json.dumps(body)}

def lambda_handler(event, context):
    try:
        body = event.get("body","{}")
        if event.get("isBase64Encoded"): body = base64.b64decode(body).decode("utf-8")
        doc = json.loads(body)
        validate(instance=doc, schema=SCHEMA)

        ts = doc.get("timestamp") or datetime.now(timezone.utc).isoformat()
        day, svc = ts[:10], doc.get("service_name","unknown")
        key = f"year={day[0:4]}/month={day[5:7]}/day={day[8:10]}/service={svc}/{int(time.time()*1000)}.json.gz"
        s3.put_object(Bucket=RAW_BUCKET, Key=key,
                      Body=gzip.compress((json.dumps(doc)+"\n").encode("utf-8")),
                      ContentType="application/json", ContentEncoding="gzip")
        return resp(200, {"status":"accepted","key":key})
    except ValidationError as ve:
        return resp(400, {"error":"invalid_payload","message":ve.message})
    except Exception as e:
        return resp(500, {"error":"ingest_failed","message":str(e)})
