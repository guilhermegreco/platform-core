FROM python:3.12-slim

WORKDIR /app

COPY app.py .

RUN pip install flask==3.* psycopg2-binary==2.* redis>=4 boto3==1.*

EXPOSE 8080

CMD ["python", "app.py"]
