FROM python:3.7-slim

WORKDIR /app
ADD hello.py requirements.txt ./
RUN pip install -r requirements.txt

ENV FLASK_APP=hello.py
ENTRYPOINT ["python3", "/usr/local/bin/flask", "run", "--host=0.0.0.0"]
