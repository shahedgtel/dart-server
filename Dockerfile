# 1️⃣ Use Dart stable version as base image
FROM dart:stable

# 2️⃣ Set working directory inside the container
WORKDIR /app

# 3️⃣ Copy pubspec files and install dependencies
COPY pubspec.* ./
RUN dart pub get

# 4️⃣ Copy the rest of the project code
COPY . .

# 5️⃣ Expose port 8080 (this is the port the server will run on)
EXPOSE 8080

# 6️⃣ Command to run your server
CMD ["dart", "run", "bin/server.dart"]
