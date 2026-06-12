FROM python:3.12-slim

WORKDIR /app

COPY app.py .

RUN pip install flask psycopg2-binary redis boto3

EXPOSE 8080

CMD ["python", "app.py"]
