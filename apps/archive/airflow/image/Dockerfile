FROM apache/airflow:3.1.3
COPY requirements.txt /
RUN pip install --no-cache-dir "apache-airflow==${AIRFLOW_VERSION}" -r /requirements.txt
COPY --chown=airflow:root dags/ /opt/airflow/dags/
ENV AIRFLOW__CORE__LOAD_EXAMPLES=False