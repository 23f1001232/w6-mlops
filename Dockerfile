FROM python:3.11-slim

WORKDIR /app

# install build deps if needed
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# copy app + model
COPY iris_fastapi.py .
COPY model.joblib .

ENV PORT=8000

EXPOSE 8000

CMD ["uvicorn", "iris_fastapi:app", "--host", "0.0.0.0", "--port", "8000"]

